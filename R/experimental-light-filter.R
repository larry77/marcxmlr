# Experimental C3: XML-event screening + selected-only native planning/writing.
# Not exported. Public read_marcxml() (no filters) remains unmodified.
# The first screening callback sees original source positions; output record_id
# is compacted to consecutive 1..N after native materialization.
.prototype_read_marcxml_light_filtered <- function(
    file, filter_tags, record_filter, n_max = Inf,
    screen_batch_records = 1000L, batch_records = 5000L) {
  batch_records <- .validate_positive_whole_number(batch_records, "batch_records")
  plan <- .prototype_filter_plan(
    file, filter_tags, record_filter, n_max, screen_batch_records,
    .light = TRUE
  )
  on.exit(.native_marcxml_recovery_plan_close(plan), add = TRUE)
  info <- .native_marcxml_recovery_plan_info(plan)
  if (info$records_valid == 0) return(.empty_marcxml())
  sources <- as.integer(info$source_record_per_valid)

  reader <- .native_marcxml_recovery_reader_open(plan)
  on.exit(.native_marcxml_recovery_reader_close(reader), add = TRUE)
  parts <- list()
  repeat {
    batch <- .native_marcxml_recovery_reader_next(reader, batch_records)
    if (is.null(batch)) break
    parts[[length(parts) + 1L]] <- batch$data
  }
  result <- .bind_marcxml_results(parts)
  ids <- match(result$record_id, sources)
  if (anyNA(ids)) stop("C3 materializer returned an unplanned record ID.", call. = FALSE)
  result$record_id <- ids
  result
}
