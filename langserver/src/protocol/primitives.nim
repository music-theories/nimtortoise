import resources/resource_types
import resources/resource_utils
export resource_types, resource_utils

import json, options

type
  OptionalSeq*[T] = Option[seq[T]]
  OptionalNode* = Option[JsonNode]
  uinteger* = range[0 .. (1 shl 31 - 1)]
