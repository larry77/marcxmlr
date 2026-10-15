# C4 research prototype: native materialization of selected byte ranges.
# Intentionally separate from exported read_marcxml()/marcxml_to_parquet().
# The offset index is currently produced by tools/c4-offset/record_offset_index.c.

.prototype_c4_visit_offsets <- function(file, offsets, consume,
                                        batch_records = 500L,
                                        batch_bytes = 16 * 1024^2,
                                        .profile = FALSE,
                                        .engine = c("dom", "reader")) {
  .engine <- match.arg(.engine)
  file <- normalizePath(file, winslash = "/", mustWork = TRUE)
  if (!is.data.frame(offsets) ||
      !all(c("start_byte", "end_byte") %in% names(offsets))) {
    stop("`offsets` must contain `start_byte` and `end_byte` columns.",
         call. = FALSE)
  }
  if (!is.function(consume)) stop("`consume` must be a function.", call. = FALSE)
  batch_records <- .validate_positive_whole_number(batch_records, "batch_records")
  batch_bytes <- .validate_positive_whole_number(batch_bytes, "batch_bytes")
  starts <- as.double(offsets$start_byte)
  ends <- as.double(offsets$end_byte)
  n <- length(starts)
  if (n > .Machine$integer.max ||
      any(!is.finite(starts)) || any(!is.finite(ends)) ||
      any(starts < 0) || any(ends <= starts) ||
      any(starts != floor(starts)) || any(ends != floor(ends)) ||
      any(ends > file.info(file)$size) ||
      (n > 1 && any(starts[-1L] < ends[-n]))) {
    stop("C4 requires ordered, non-overlapping, valid source byte ranges.",
         call. = FALSE)
  }
  # The batch combines a maximum number of records with a maximum input size;
  # this prevents expanding all selected XML fragments at once.
  i <- 1L
  profile <- c(native_read_offsets_s = 0, native_xml_parse_s = 0,
               native_count_s = 0, native_allocation_s = 0,
               native_init_s = 0, native_write_s = 0,
               native_cleanup_s = 0)
  clock <- function() unname(proc.time()[["elapsed"]])
  visit_start <- if (isTRUE(.profile)) clock() else NULL
  r_call_s <- 0
  r_tibble_s <- 0
  r_consume_s <- 0
  batches <- 0L
  while (i <= n) {
    j <- i
    bytes <- 0
    repeat {
      next_bytes <- ends[[j]] - starts[[j]]
      if (next_bytes > batch_bytes) {
        stop("Selected record exceeds `batch_bytes`; increase the bound.",
             call. = FALSE)
      }
      if (j > i && bytes + next_bytes > batch_bytes) break
      bytes <- bytes + next_bytes
      if (j == n || (j - i + 1L) >= batch_records) {
        j <- j + 1L
        break
      }
      j <- j + 1L
    }
    selected <- i:(j - 1L)
    if (isTRUE(.profile)) phase_start <- clock()
    parser <- if (.engine == "reader")
      C_marcxml_offset_parse_batch_stream else C_marcxml_offset_parse_batch
    columns <- .Call(
      parser, file,
      starts[selected], ends[selected], as.integer(i)
    )
    if (isTRUE(.profile)) r_call_s <- r_call_s + clock() - phase_start
    current_profile <- attr(columns, "c4_native_profile")
    if (!is.null(current_profile)) profile <- profile + current_profile
    # This metadata describes profiling, not canonical data; do not propagate
    # it into tibbles or their final binding.
    attr(columns, "c4_native_profile") <- NULL
    if (isTRUE(.profile)) phase_start <- clock()
    batch <- tibble::new_tibble(columns,
                                nrow = length(columns[[1L]]))
    if (isTRUE(.profile)) r_tibble_s <- r_tibble_s + clock() - phase_start
    if (isTRUE(.profile)) phase_start <- clock()
    consume(batch)
    if (isTRUE(.profile)) r_consume_s <- r_consume_s + clock() - phase_start
    batches <- batches + 1L
    i <- j
  }
  r_profile <- NULL
  if (isTRUE(.profile)) {
    visit_s <- clock() - visit_start
    r_profile <- c(r_visit_s = visit_s, r_call_s = r_call_s,
                   r_tibble_s = r_tibble_s, r_consume_s = r_consume_s,
                   r_other_s = visit_s - r_call_s - r_tibble_s - r_consume_s)
  }
  invisible(list(profile = profile, r_profile = r_profile,
                 batches = batches, records = n))
}

.prototype_c4_native_read_offsets <- function(file, offsets,
                                              batch_records = 500L,
                                              batch_bytes = 16 * 1024^2,
                                              .profile = FALSE,
                                              .engine = c("dom", "reader"),
                                              .binding = c("purrr", "native")) {
  .engine <- match.arg(.engine)
  .binding <- match.arg(.binding)
  parts <- list()
  read_started <- if (isTRUE(.profile)) unname(proc.time()[["elapsed"]]) else NULL
  info <- .prototype_c4_visit_offsets(
    file, offsets,
    consume = function(batch) parts[[length(parts) + 1L]] <<- batch,
    batch_records = batch_records, batch_bytes = batch_bytes,
    .profile = .profile, .engine = .engine
  )
  if (isTRUE(.profile)) bind_started <- unname(proc.time()[["elapsed"]])
  result <- if (!length(parts)) {
    .empty_marcxml()
  } else if (.binding == "native") {
    # C copies only the known 11 canonical columns; no vctrs type dispatch.
    columns <- .Call(C_marcxml_c4_bind_parts, parts)
    tibble::new_tibble(columns, nrow = length(columns[[1L]]))
  } else {
    .bind_marcxml_results(parts)
  }
  attr(result, "c4_native_profile") <- NULL
  if (isTRUE(.profile)) {
    end <- unname(proc.time()[["elapsed"]])
    return(list(
      canonical = result, native_profile = info$profile,
      r_profile = c(info$r_profile, r_bind_s = end - bind_started,
                    r_total_read_s = end - read_started),
      batches = info$batches
    ))
  }
  result
}

# Experimental bounded-memory Parquet sink. The same offset mechanism and
# native C writer are reused; no full selected canonical table is built in R.
.prototype_c4_native_to_parquet_offsets <- function(
    file, offsets, output_dir, batch_records = 500L,
    batch_bytes = 16 * 1024^2, compression = "snappy",
    .engine = c("dom", "reader")) {
  .engine <- match.arg(.engine)
  if (!requireNamespace("arrow", quietly = TRUE))
    stop("The Arrow package is required.", call. = FALSE)
  if (file.exists(output_dir))
    stop("`output_dir` already exists.", call. = FALSE)
  parent <- dirname(output_dir)
  if (!dir.exists(parent))
    stop("Output parent directory does not exist.", call. = FALSE)
  stage <- tempfile("c4-native-", tmpdir = parent)
  if (!dir.create(stage))
    stop("Could not create temporary Parquet output directory.", call. = FALSE)
  done <- FALSE
  on.exit(if (!done) unlink(stage, recursive = TRUE, force = TRUE), add = TRUE)
  n_parts <- 0L
  records <- 0L
  rows <- 0
  .prototype_c4_visit_offsets(
    file, offsets,
    consume = function(batch) {
      n_parts <<- n_parts + 1L
      arrow::write_parquet(
        batch,
        file.path(stage, sprintf("part-%06d.parquet", n_parts)),
        compression = compression
      )
      records <<- records + length(unique(batch$record_id))
      rows <<- rows + nrow(batch)
    },
    batch_records = batch_records, batch_bytes = batch_bytes,
    .engine = .engine
  )
  if (n_parts == 0L) {
    n_parts <- 1L
    arrow::write_parquet(.empty_marcxml(),
                         file.path(stage, "part-000001.parquet"),
                         compression = compression)
  }
  if (!file.rename(stage, output_dir))
    stop("Could not publish C4 Parquet directory.", call. = FALSE)
  done <- TRUE
  invisible(tibble::tibble(output_dir = normalizePath(output_dir),
                           records = records, rows = rows,
                           parquet_files = n_parts))
}
