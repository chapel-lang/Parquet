// Copyright Hewlett Packard Enterprise Development LP.
//
// Tests for the list/segarray write API: writeListColumn, writeStrListColumn,
// and (indirectly) the private helper writeListColumnComponent, which is
// exercised through writeListColumn.
//
// Scenarios are modeled on Arkouda's SegArray Parquet tests
// (arkouda/tests/pandas/io_test.py): regular numeric lists, lists containing
// empty segments, and lists of strings.
//
// Writes are validated with the single-file readers (getArrSize, getArrType,
// getListData, getListColSize) and, for numeric values, the distributed list
// read path (readListFilesByName) -- which also exercises the getSubdomains and
// domain_intersection helpers.
use UnitTest;
use Parquet;
use TestUtil;

import Path;
import FileSystem as FS;
import BlockDist.blockDist;

// Check a numeric list column across all per-locale files: element type,
// per-list sizes (`expectedSizes`, one per list) and, for int64, the flat
// values.
proc checkListColumn(test: borrowed Test, filePath: string, colName: string,
                     const ref segments: [] int, const ref values: [] ?t,
                     expectedSizes: [] int, elt: ArrowTypes) throws {
  const numLocs = segments.targetLocales().size;
  var rowsPerFile, valsPerFile: [0..#numLocs] int;

  for ((f, locDom), idx) in zip(localeChunks(segments, filePath), 0..#numLocs) {
    test.assertTrue(FS.isFile(f));
    test.assertEqual(getArrSize(f), locDom.size);
    rowsPerFile[idx] = locDom.size;
    valsPerFile[idx] = + reduce expectedSizes[locDom];
    if locDom.size == 0 then continue;

    test.assertEqual(getArrType(f, colName), ArrowTypes.list);
    test.assertEqual(getListData(f, colName), elt);

    var segSizes: [0..#locDom.size] int;
    test.assertEqual(getListColSize(f, colName, segSizes), valsPerFile[idx]);
    for (i, r) in zip(0..#locDom.size, locDom) do
      test.assertEqual(segSizes[i], expectedSizes[r]);
  }

  if elt == ArrowTypes.int64 {
    const readVals = readListValues(t, localeFiles(filePath, numLocs),
                                    rowsPerFile, valsPerFile, colName, elt);
    for i in values.domain do test.assertEqual(readVals[i], values[i]);
  }
}

// Regular numeric list column: [[0, 1, 2], [3], [4, 5]]
proc testWriteListColumn(test: borrowed Test) throws {
  requireTestLocales(test);
  var segments = blockDist.createArray(0..#3, int);
  var values = blockDist.createArray(0..#6, int);
  segments = [0, 3, 4];               // per-list start index into values
  values = [0, 1, 2, 3, 4, 5];

  // manual enter/exit instead of `manage`: a throw out of a manage body
  // double-deinits the enclosing arrays (see https://github.com/chapel-lang/chapel/issues/29430)
  var temp = new tempDir();
  temp.enterContext();
  defer { try! temp.exitContext(nil); }

  const filePath = Path.joinPath(temp.path, "listcol.parquet");
  const overwritten = writeListColumn(filePath, "col", segments, values);
  test.assertFalse(overwritten);

  checkListColumn(test, filePath, "col", segments, values, [3, 1, 2],
                  ArrowTypes.int64);
}

// Numeric list column with empty segments: [[], [0, 1], [], [3, 4, 5, 6], []]
proc testWriteListColumnEmptySegments(test: borrowed Test) throws {
  requireTestLocales(test);
  var segments = blockDist.createArray(0..#5, int);
  var values = blockDist.createArray(0..#6, int);
  segments = [0, 0, 2, 2, 6];
  values = [0, 1, 3, 4, 5, 6];

  // manual enter/exit instead of `manage`: a throw out of a manage body
  // double-deinits the enclosing arrays (see https://github.com/chapel-lang/chapel/issues/29430)
  var temp = new tempDir();
  temp.enterContext();
  defer { try! temp.exitContext(nil); }

  const filePath = Path.joinPath(temp.path, "emptysegs.parquet");
  writeListColumn(filePath, "col", segments, values);

  checkListColumn(test, filePath, "col", segments, values, [0, 2, 0, 4, 0],
                  ArrowTypes.int64);
}

// Compression path: same data written with SNAPPY should round-trip.
proc testWriteListColumnCompressed(test: borrowed Test) throws {
  requireTestLocales(test);
  var segments = blockDist.createArray(0..#2, int);
  var values = blockDist.createArray(0..#5, int);
  segments = [0, 2];
  values = [10, 11, 12, 13, 14];

  // manual enter/exit instead of `manage`: a throw out of a manage body
  // double-deinits the enclosing arrays (see https://github.com/chapel-lang/chapel/issues/29430)
  var temp = new tempDir();
  temp.enterContext();
  defer { try! temp.exitContext(nil); }

  const filePath = Path.joinPath(temp.path, "listsnappy.parquet");
  writeListColumn(filePath, "col", segments, values,
                  compression=CompressionType.SNAPPY);

  checkListColumn(test, filePath, "col", segments, values, [2, 3],
                  ArrowTypes.int64);
}

// List-of-strings column: [["a", "bb"], ["ccc"], []]
proc testWriteStrListColumn(test: borrowed Test) throws {
  requireTestLocales(test);
  var segments = blockDist.createArray(0..#3, int);   // per-list start into strings
  var offsets = blockDist.createArray(0..#3, int);    // per-string start byte
  var vals = blockDist.createArray(0..#9, uint(8));   // null-terminated bytes
  segments = [0, 2, 3];
  offsets = [0, 2, 5];
  // "a\0" "bb\0" "ccc\0"
  vals[0] = "a".toByte(); vals[1] = 0;
  vals[2] = "b".toByte(); vals[3] = "b".toByte(); vals[4] = 0;
  vals[5] = "c".toByte(); vals[6] = "c".toByte(); vals[7] = "c".toByte(); vals[8] = 0;

  // manual enter/exit instead of `manage`: a throw out of a manage body
  // double-deinits the enclosing arrays (see https://github.com/chapel-lang/chapel/issues/29430)
  var temp = new tempDir();
  temp.enterContext();
  defer { try! temp.exitContext(nil); }

  const filePath = Path.joinPath(temp.path, "strlist.parquet");
  const overwritten = writeStrListColumn(filePath, "col", segments, offsets,
                                         vals);
  test.assertFalse(overwritten);

  // list sizes [2, 1, 0]; string bytes are only checked structurally
  checkListColumn(test, filePath, "col", segments, vals, [2, 1, 0],
                  ArrowTypes.stringArr);
}

UnitTest.main();
