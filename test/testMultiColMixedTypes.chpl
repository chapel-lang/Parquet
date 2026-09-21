// Copyright Hewlett Packard Enterprise Development LP.
//
// Reproducer for the ASAN crash seen in Arkouda's
// tests/pandas/io_test.py::TestParquet::test_multi_col_write.
//
// Mirrors Arkouda's `make_multi_dtype_dict()` (15 columns, 4 rows): flat
// int/uint/bool/real columns, numeric SegArray columns, a Strings column, and
// several SegArray-of-Strings columns (including empty lists, empty strings,
// and lists that run to the end of the values). All columns are registered on
// one `pqWriteOp` with `distributed = true`, exactly as
// ParquetMsg.writeMultiColWithOps does.
use UnitTest;
use Parquet;
use TestUtil;

import Path;
import FileSystem as FS;
import BlockDist.blockDist;
import IO.format;

// Build Arkouda-style SegString components (per-string start offsets and
// null-terminated bytes) as block-distributed arrays.
proc makeSegStrings(const strs: [] string) {
  var offsets = blockDist.createArray(0..#strs.size, int);
  var total = 0;
  for s in strs do total += s.numBytes + 1;
  var values = blockDist.createArray(0..#total, uint(8));

  var off = 0;
  for (i, s) in zip(0..#strs.size, strs) {
    offsets[i] = off;
    for (j, b) in zip(0..#s.numBytes, s.bytes()) do values[off + j] = b;
    values[off + s.numBytes] = 0;
    off += s.numBytes + 1;
  }
  return (offsets, values);
}

proc toBlock(const A: [] ?t) {
  var B = blockDist.createArray(0..#A.size, t);
  B = A;
  return B;
}

// With `distributed = true` each locale writes `base_LOCALE####.parquet`
// holding only its local block of rows.
proc localeFile(dirPath: string, base: string, idx: int) throws {
  return Path.joinPath(dirPath, "%s_LOCALE%04i.parquet".format(base, idx));
}

// Column names are built at runtime (like Arkouda's, which arrive in a
// message) so their buffers are temporaries rather than immortal literals.
proc col(i: int) { return "c_" + i:string; }

proc testMultiColWriteMixedTypes(test: borrowed Test) throws {
  requireTestLocales(test);
  const numRows = 4;

  // c_1: int64 pdarray
  const c1 = toBlock([min(int), -1, 0, max(int)]);
  // c_2: SegArray(int64) segments [0, 0, 9, 14], values arange(-10, 10)
  const c2Segs = toBlock([0, 0, 9, 14]);
  var c2Vals = blockDist.createArray(0..#20, int);
  c2Vals = -10..9;
  // c_3: uint64 pdarray
  const c3 = toBlock([(2**63 + 3):uint, (2**63 + 4):uint,
                      (2**63 + 5):uint, (2**63 + 6):uint]);
  // c_4: SegArray(uint64) segments [0, 5, 10, 10], 15 values
  const c4Segs = toBlock([0, 5, 10, 10]);
  var c4Vals = blockDist.createArray(0..#15, uint);
  forall (v, i) in zip(c4Vals, 0..) do v = (2**63 + i):uint;
  // c_5: bool pdarray
  const c5 = toBlock([false, true, false, false]);
  // c_6: SegArray(bool) segments [0, 0, 5, 10], 15 values
  const c6Segs = toBlock([0, 0, 5, 10]);
  var c6Vals = blockDist.createArray(0..#15, bool);
  forall (v, i) in zip(c6Vals, 0..) do v = (i % 3 == 0);
  // c_7: float64 pdarray
  const c7 = toBlock([-0.0, min(real), nan, inf]);
  // c_8: SegArray(float64) segments [0, 9, 14, 14], 14 values
  const c8Segs = toBlock([0, 9, 14, 14]);
  const c8Vals = toBlock([nan, min(real), -inf, -7.0, -3.14, -0.0, 0.0, 3.14,
                          7.0, max(real), inf, nan, nan, nan]);
  // c_9: Strings
  const (c9Offs, c9Bytes) = makeSegStrings(["abc", " ", "xyz", ""]);
  // c_10 .. c_15: SegArray(Strings)
  const letters = ["a", "b", "c", "d", "e", "f", "g", "h", "i"];
  const c10Segs = toBlock([0, 2, 5, 5]);
  const (c10Offs, c10Bytes) = makeSegStrings(letters);
  const c11Segs = toBlock([0, 2, 2, 2]);
  const (c11Offs, c11Bytes) =
      makeSegStrings(["a", "b", "", "c", "d", "e", "f", "g", "h", "i"]);
  const c12Segs = toBlock([0, 0, 2, 2]);
  const (c12Offs, c12Bytes) = makeSegStrings(letters);
  const c13Segs = toBlock([0, 2, 3, 3]);
  const (c13Offs, c13Bytes) =
      makeSegStrings(["", "'", " ", "test", "", "'", "", " ", ""]);
  const c14Segs = toBlock([0, 5, 5, 8]);
  const (c14Offs, c14Bytes) = makeSegStrings(letters);
  const c15Segs = toBlock([0, 5, 8, 8]);
  const (c15Offs, c15Bytes) =
      makeSegStrings(["abc", "123", "xyz", "l", "m", "n", "o", "p", "arkouda"]);

  for comp in CompressionType {
    // manual enter/exit instead of `manage`: a throw out of a manage body
    // double-deinits the enclosing arrays (see https://github.com/chapel-lang/chapel/issues/29430)
    var temp = new tempDir();
    temp.enterContext();
    defer { try! temp.exitContext(nil); }

    const filePath = Path.joinPath(temp.path, "multi_col.parquet");

    var op = new pqWriteOp(filePath, c1.domain);
    op.compression = comp: int;
    op.distributed = true;

    op.registerColumn(c1, col(1));
    op.registerListColumn(c2Segs, c2Vals, col(2));
    op.registerColumn(c3, col(3));
    op.registerListColumn(c4Segs, c4Vals, col(4));
    op.registerColumn(c5, col(5));
    op.registerListColumn(c6Segs, c6Vals, col(6));
    op.registerColumn(c7, col(7));
    op.registerListColumn(c8Segs, c8Vals, col(8));
    op.registerStrColumn(c9Offs, c9Bytes, col(9));
    op.registerStrListColumn(c10Segs, c10Offs, c10Bytes, col(10));
    op.registerStrListColumn(c11Segs, c11Offs, c11Bytes, col(11));
    op.registerStrListColumn(c12Segs, c12Offs, c12Bytes, col(12));
    op.registerStrListColumn(c13Segs, c13Offs, c13Bytes, col(13));
    op.registerStrListColumn(c14Segs, c14Offs, c14Bytes, col(14));
    op.registerStrListColumn(c15Segs, c15Offs, c15Bytes, col(15));
    op.write();

    // flat column round-trip for this locale's rows
    proc checkFlat(f: string, name: string, const A: [], locDom) throws {
      var In: [0..#locDom.size] A.eltType;
      readColumn(f, name, In);
      for (i, r) in zip(0..#locDom.size, locDom) do test.assertEqual(In[i], A[r]);
    }

    // list column: element type and per-list sizes for this locale's rows
    proc checkList(f: string, name: string, elt: ArrowTypes,
                   expectedSizes: [] int, locDom) throws {
      test.assertEqual(getArrType(f, name), ArrowTypes.list);
      test.assertEqual(getListData(f, name), elt);
      var segSizes: [0..#locDom.size] int;
      const total = getListColSize(f, name, segSizes);
      test.assertEqual(total, + reduce expectedSizes[locDom]);
      for (i, r) in zip(0..#locDom.size, locDom) do
        test.assertEqual(segSizes[i], expectedSizes[r]);
    }

    for (loc, idx) in zip(c1.targetLocales(), 0..#c1.targetLocales().size) {
      const locDom = c1.localSubdomain(loc);
      const f = localeFile(temp.path, "multi_col", idx);
      test.assertTrue(FS.isFile(f));
      test.assertEqual(getNumCols(f), 15);
      test.assertEqual(getArrSize(f), locDom.size);
      if locDom.size == 0 then continue;

      checkFlat(f, "c_1", c1, locDom);
      checkFlat(f, "c_3", c3, locDom);
      checkFlat(f, "c_5", c5, locDom);

      // string column: bytes (incl. null terminators) of this locale's rows
      test.assertEqual(getArrType(f, "c_9"), ArrowTypes.stringArr);
      const startByte = c9Offs[locDom.low];
      const endByte = if locDom.high == c9Offs.domain.high
                        then c9Bytes.size
                        else c9Offs[locDom.high + 1];
      var c9OffsIn: [0..#locDom.size] int;
      test.assertEqual(getStrColSize(f, "c_9", c9OffsIn), endByte - startByte);

      checkList(f, "c_10", ArrowTypes.stringArr, [2, 3, 0, 4], locDom);
      checkList(f, "c_11", ArrowTypes.stringArr, [2, 0, 0, 8], locDom);
      checkList(f, "c_12", ArrowTypes.stringArr, [0, 2, 0, 7], locDom);
      checkList(f, "c_13", ArrowTypes.stringArr, [2, 1, 0, 6], locDom);
      checkList(f, "c_14", ArrowTypes.stringArr, [5, 0, 3, 1], locDom);
      checkList(f, "c_15", ArrowTypes.stringArr, [5, 3, 0, 1], locDom);

      checkList(f, "c_2", ArrowTypes.int64,   [0, 9, 5, 6], locDom);
      checkList(f, "c_4", ArrowTypes.uint64,  [5, 5, 0, 5], locDom);
      checkList(f, "c_6", ArrowTypes.boolean, [0, 5, 5, 5], locDom);
      checkList(f, "c_8", ArrowTypes.double,  [9, 5, 0, 0], locDom);
    }
  }
}

UnitTest.main();
