import ./[forest_types, forest_utile]
import ../resources/resources

proc getAllNimsFiles*(rootPath: DirPathAbs): seq[FilePathAbs] =
  return getAllFiles(rootPath, "*.nims")

