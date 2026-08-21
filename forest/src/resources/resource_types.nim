type
  FileUri*     = distinct string ## A file:// URI (e.g. "file:///Users/foo/bar.nim")
  FilePathAbs* = distinct string ## An absolute filesystem path to a file (e.g. "/Users/foo/bar.nim")
  FilePathRel* = distinct string ## A relative filesystem path to a file (e.g. "src/foo.nim")
  DirPathAbs*  = distinct string ## An absolute filesystem path to a directory (e.g. "/Users/foo/")
  DirPathRel*  = distinct string ## A relative filesystem path to a directory (e.g. "src/")
