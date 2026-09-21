// Copyright Hewlett Packard Enterprise Development LP.
module TestUtil {
  import FileSystem as FS;
  import Time;
  import Path;
  import IO.format;
  import ChplConfig.CHPL_COMM;
  import OS.POSIX.getenv;
  import Parquet.{readListFilesByName, ArrowTypes};
  use CTypes;

  /*
    Pin the locale count every test runs with. If PARQUET_TEST_NUM_LOCALES is
    set (and the build is multi-locale), the test reports that it requires
    that many locales; mason then re-runs the test binary with `-nl <n>`.
    Call at the top of every test proc.
  */
  // `test` is left generic on purpose: a `borrowed Test` formal would make
  // UnitTest discover this helper as a test of its own.
  proc requireTestLocales(test) throws {
    if CHPL_COMM == "none" then return;
    const raw = getenv("PARQUET_TEST_NUM_LOCALES");
    if raw == nil then return;
    const n = string.createCopyingBuffer(raw): int;
    test.addNumLocales(n);
  }

  record tempDir: contextManager {

    var path = "temp_"+Time.dateTime.now():string;

    proc ref enterContext() ref throws {
      FS.mkdir(path, parents=true);
      return this;
    }

    proc ref exitContext(in err: owned Error?) throws {
      FS.rmTree(path);
      if err then throw err;
    }
  }

  /*
    The per-locale files a distributed write of `filePath` produces:
    `<prefix>_LOCALE####<ext>`, one per target locale.
  */
  proc localeFiles(filePath: string, numFiles: int): [] string throws {
    const (prefix, ext) = Path.splitExt(filePath);
    var files: [0..#numFiles] string;
    for i in 0..#numFiles do
      files[i] = "%s_LOCALE%04i%s".format(prefix, i, ext);
    return files;
  }

  /*
    Yields `(file, locDom)` for each target locale of `A`: the file that
    locale wrote and the rows (indices of `A`) it holds. `pqWriteOp` writes
    plain `filePath` when there is a single target locale and `distributed`
    is false; pass `singleFileIfOneLocale=true` for that case.
  */
  iter localeChunks(const ref A: [], filePath: string,
                    singleFileIfOneLocale=false) {
    const locs = A.targetLocales();
    if singleFileIfOneLocale && locs.size == 1 {
      yield (filePath, A.localSubdomain(locs[locs.domain.low]));
    } else {
      const files = try! localeFiles(filePath, locs.size);
      for (loc, f) in zip(locs, files) do yield (f, A.localSubdomain(loc));
    }
  }

  /*
    Read the flat values of a numeric list column spread over `files`.
    `rowsPerFile` is the number of lists and `valsPerFile` the number of
    values each file holds.
  */
  proc readListValues(type t, files: [] string, rowsPerFile: [] int,
                      valsPerFile: [] int, colName: string,
                      ty: ArrowTypes) throws {
    const numRows = + reduce rowsPerFile;
    var vals: [0..#(+ reduce valsPerFile)] t;
    var segSizes: [0..#numRows] int;
    var offsets: [0..#numRows] int;
    readListFilesByName(vals, rowsPerFile, segSizes, offsets, files,
                        valsPerFile, colName, ty);
    return vals;
  }
}
