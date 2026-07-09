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

// Locate the single per-locale file written for `base` under `dirPath`.
proc listFile(dirPath: string, base: string) throws {
  const files = FS.glob(Path.joinPath(dirPath, base + "_LOCALE*.parquet"));
  return files[0];
}

// Read back the flat values of a numeric (int64) list column through the
// package's list read path.
proc readIntListValues(filename: string, colName: string, n: int,
                       numLists: int) throws {
  var vals: [0..#n] int;
  var rowsPerFile = [numLists];       // number of lists in the (single) file
  var segSizes: [0..#numLists] int;
  var offsets: [0..#numLists] int;
  readListFilesByName(vals, rowsPerFile, segSizes, offsets,
                      [filename], [n], colName, ArrowTypes.int64);
  return vals;
}

// Regular numeric list column: [[0, 1, 2], [3], [4, 5]]
proc testWriteListColumn(test: borrowed Test) throws {
  var segments = blockDist.createArray(0..#3, int);
  var values = blockDist.createArray(0..#6, int);
  segments = [0, 3, 4];               // per-list start index into values
  values = [0, 1, 2, 3, 4, 5];

  manage new tempDir() as temp {
    const filePath = Path.joinPath(temp.path, "listcol.parquet");
    const overwritten = writeListColumn(filePath, "col", segments, values);
    test.assertFalse(overwritten);

    const f = listFile(temp.path, "listcol");
    test.assertTrue(FS.isFile(f));

    // structure
    test.assertEqual(getArrSize(f), 3);                     // 3 lists (rows)
    test.assertEqual(getArrType(f, "col"), ArrowTypes.list);
    test.assertEqual(getListData(f, "col"), ArrowTypes.int64);

    var segSizes: [0..#3] int;
    const total = getListColSize(f, "col", segSizes);
    test.assertEqual(total, 6);
    test.assertEqual(segSizes[0], 3);
    test.assertEqual(segSizes[1], 1);
    test.assertEqual(segSizes[2], 2);

    // values round-trip
    const readVals = readIntListValues(f, "col", 6, 3);
    for i in 0..#6 do test.assertEqual(readVals[i], values[i]);
  }
}

// Numeric list column with empty segments: [[], [0, 1], [], [3, 4, 5, 6], []]
proc testWriteListColumnEmptySegments(test: borrowed Test) throws {
  var segments = blockDist.createArray(0..#5, int);
  var values = blockDist.createArray(0..#6, int);
  segments = [0, 0, 2, 2, 6];
  values = [0, 1, 3, 4, 5, 6];

  manage new tempDir() as temp {
    const filePath = Path.joinPath(temp.path, "emptysegs.parquet");
    writeListColumn(filePath, "col", segments, values);

    const f = listFile(temp.path, "emptysegs");

    test.assertEqual(getArrSize(f), 5);                     // 5 lists (rows)
    test.assertEqual(getArrType(f, "col"), ArrowTypes.list);

    var segSizes: [0..#5] int;
    const total = getListColSize(f, "col", segSizes);
    test.assertEqual(total, 6);
    const expected = [0, 2, 0, 4, 0];
    for i in 0..#5 do test.assertEqual(segSizes[i], expected[i]);
  }
}

// Compression path: same data written with SNAPPY should round-trip.
proc testWriteListColumnCompressed(test: borrowed Test) throws {
  var segments = blockDist.createArray(0..#2, int);
  var values = blockDist.createArray(0..#5, int);
  segments = [0, 2];
  values = [10, 11, 12, 13, 14];

  manage new tempDir() as temp {
    const filePath = Path.joinPath(temp.path, "listsnappy.parquet");
    writeListColumn(filePath, "col", segments, values,
                    compression=CompressionType.SNAPPY);

    const f = listFile(temp.path, "listsnappy");
    test.assertEqual(getArrType(f, "col"), ArrowTypes.list);

    var segSizes: [0..#2] int;
    const total = getListColSize(f, "col", segSizes);
    test.assertEqual(total, 5);
    test.assertEqual(segSizes[0], 2);
    test.assertEqual(segSizes[1], 3);

    const readVals = readIntListValues(f, "col", 5, 2);
    for i in 0..#5 do test.assertEqual(readVals[i], values[i]);
  }
}

// List-of-strings column: [["a", "bb"], ["ccc"], []]
proc testWriteStrListColumn(test: borrowed Test) throws {
  var segments = blockDist.createArray(0..#3, int);   // per-list start into strings
  var offsets = blockDist.createArray(0..#3, int);    // per-string start byte
  var vals = blockDist.createArray(0..#9, uint(8));   // null-terminated bytes
  segments = [0, 2, 3];
  offsets = [0, 2, 5];
  // "a\0" "bb\0" "ccc\0"
  vals[0] = 97; vals[1] = 0;
  vals[2] = 98; vals[3] = 98; vals[4] = 0;
  vals[5] = 99; vals[6] = 99; vals[7] = 99; vals[8] = 0;

  manage new tempDir() as temp {
    const filePath = Path.joinPath(temp.path, "strlist.parquet");
    const overwritten = writeStrListColumn(filePath, "col", segments, offsets,
                                           vals);
    test.assertFalse(overwritten);

    const f = listFile(temp.path, "strlist");
    test.assertTrue(FS.isFile(f));

    test.assertEqual(getArrSize(f), 3);                     // 3 lists (rows)
    test.assertEqual(getArrType(f, "col"), ArrowTypes.list);
    test.assertEqual(getListData(f, "col"), ArrowTypes.stringArr);

    var segSizes: [0..#3] int;
    const total = getListColSize(f, "col", segSizes);
    test.assertEqual(total, 3);                             // 3 strings total
    test.assertEqual(segSizes[0], 2);
    test.assertEqual(segSizes[1], 1);
    test.assertEqual(segSizes[2], 0);
  }
}

UnitTest.main();
