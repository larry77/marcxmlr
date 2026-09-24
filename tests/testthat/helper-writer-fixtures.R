canonical_writer_fixture <- function() {
  tibble::tibble(
    record_id = c(rep(1L, 9L), rep(2L, 2L)),
    field_type = c(
      "leader", "controlfield",
      rep("datafield", 7L),
      "leader", "controlfield"
    ),
    tag = c(
      "LDR", "001",
      "245", "245",
      "650", "650",
      "650", "650", "650",
      "LDR", "001"
    ),
    subfield_code = c(
      NA, NA,
      "a", "c",
      "a", "x",
      "a", "a", "v",
      NA, NA
    ),
    value = c(
      "00000cam a2200000 i 4500",
      "one",
      "A & B < C > D", "Žluťoučký kůň",
      "Libraries", "Data processing",
      "Metadata", "Cataloguing", "Standards",
      "00000cam a2200000 i 4500",
      "two"
    ),
    field_order = c(0L, 1L, 2L, 2L, 3L, 3L, 4L, 4L, 4L, 0L, 1L),
    field_occurrence = c(1L, 1L, 1L, 1L, 1L, 1L, 2L, 2L, 2L, 1L, 1L),
    ind1 = c(NA, NA, "1", "1", " ", " ", " ", " ", " ", NA, NA),
    ind2 = c(NA, NA, "0", "0", "0", "0", "0", "0", "0", NA, NA),
    subfield_order = c(NA, NA, 1L, 2L, 1L, 2L, 1L, 2L, 3L, NA, NA),
    subfield_occurrence = c(NA, NA, 1L, 1L, 1L, 1L, 1L, 2L, 1L, NA, NA)
  )
}


canonical_semantics <- function(x) {
  record_ids <- sort(unique(x$record_id))
  normalized_record_id <- match(x$record_id, record_ids)
  sub_order <- ifelse(is.na(x$subfield_order), 0L, x$subfield_order)
  idx <- order(normalized_record_id, x$field_order, sub_order)

  data.frame(
    record_id = as.integer(normalized_record_id[idx]),
    field_type = x$field_type[idx],
    tag = x$tag[idx],
    subfield_code = x$subfield_code[idx],
    value = x$value[idx],
    ind1 = x$ind1[idx],
    ind2 = x$ind2[idx],
    stringsAsFactors = FALSE
  )
}
