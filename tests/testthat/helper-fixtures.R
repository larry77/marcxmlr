canonical_columns <- c(
  "record_id",
  "field_type",
  "tag",
  "subfield_code",
  "value",
  "field_order",
  "field_occurrence",
  "ind1",
  "ind2",
  "subfield_order",
  "subfield_occurrence"
)

example_marcxml_file <- function() {
  system.file(
    "extdata",
    "example-marcxml.xml",
    package = "marcxmlr",
    mustWork = TRUE
  )
}

write_test_xml <- function(lines) {
  path <- tempfile(fileext = ".xml")
  writeLines(lines, path, useBytes = TRUE)
  path
}

sort_canonical <- function(x) {
  subfield_position <- ifelse(is.na(x$subfield_order), 0L, x$subfield_order)
  x[order(x$record_id, x$field_order, subfield_position), canonical_columns]
}
