# Experimental C4, file-level parallel Parquet filtering.
# Source this file from R. The public marcxmlr functions are not modified.
# No new native routines: reuse the installed C4 reader and the Expat
# screening helper already checked into tools/c4-offset/.
#
# One screening task per input file, followed by one writer task per file.
# Both phases use the same future.mirai + futurize file-level orchestration
# already employed by marcxmlr for multiple input files. No parallelism
# within a single MARCXML file.

.c4_parallel_tools_dir <- local({
  src <- tryCatch(sys.frame(1L)$ofile, error = function(e) NULL)
  if (is.null(src)) stop("Source parallel-files.R from its file path.")
  dirname(normalizePath(src, mustWork = TRUE))
})

.c4_parallel_clock <- function() unname(proc.time()[["elapsed"]])

.c4_parallel_paths <- function(specifications, allow_repeated = FALSE) {
  if (!is.character(specifications) || !length(specifications) ||
      anyNA(specifications) || any(!nzchar(specifications))) {
    stop("Supply at least one existing MARCXML file or glob.", call. = FALSE)
  }
  paths <- unlist(lapply(specifications, function(x) {
    x <- path.expand(x)
    if (file.exists(x) && !dir.exists(x)) return(x)
    if (dir.exists(x)) stop("Input is a directory: ", x, call. = FALSE)
    matches <- sort(Sys.glob(x))
    if (!length(matches) || any(dir.exists(matches))) {
      stop("Missing input file(s) or invalid glob: ", x, call. = FALSE)
    }
    matches
  }), use.names = FALSE)
  paths <- normalizePath(paths, winslash = "/", mustWork = TRUE)
  if (!allow_repeated && anyDuplicated(paths)) {
    stop("Duplicate input paths are not allowed (except in synthetic tests).",
         call. = FALSE)
  }
  paths
}

.c4_parallel_map <- function(x, fun, nworkers) {
  if (nworkers == 1L) return(purrr::map(x, fun))
  # Same mechanism as R/multi-file-parquet.R, not a new scheduler.
  futurize::futurize(purrr::map(x, fun))
}

.c4_parallel_screen_one <- function(file, indexer, tag, subfield, equals) {
  idx <- tempfile("c4-index-", fileext = ".tsv")
  log <- tempfile("c4-index-", fileext = ".log")
  on.exit(unlink(c(idx, log)), add = TRUE)
  t <- .c4_parallel_clock()
  status <- suppressWarnings(system2(
    indexer,
    args = shQuote(c(file, tag,
                     if (is.null(subfield)) "-" else subfield,
                     if (is.null(equals)) "-" else equals)),
    stdout = idx, stderr = log
  ))
  if (!identical(as.integer(status), 0L)) {
    stop("C4 screening failed for ", file, ":\n",
         paste(readLines(log, warn = FALSE), collapse = "\n"),
         call. = FALSE)
  }
  index <- utils::read.delim(
    idx, colClasses = c("integer", "numeric", "numeric")
  )
  if (!identical(names(index), c("source_position", "start_byte", "end_byte"))) {
    stop("Unexpected C4 index schema for ", file, call. = FALSE)
  }
  list(file = file, index = index, records = nrow(index),
       screen_s = .c4_parallel_clock() - t)
}

.c4_parallel_write_one <- function(task, batch_records, batch_bytes,
                                   compression) {
  if (!dir.create(task$path)) {
    stop("Cannot create worker output: ", task$path, call. = FALSE)
  }
  complete <- FALSE
  on.exit(if (!complete) unlink(task$path, recursive = TRUE, force = TRUE),
          add = TRUE)
  count <- 0L
  rows <- 0
  parts <- 0L
  t <- .c4_parallel_clock()

  if (!task$records) {
    arrow::write_parquet(
      marcxmlr:::.empty_marcxml(),
      sink = file.path(task$path, "part-000001.parquet"),
      compression = compression
    )
    parts <- 1L
  } else {
    marcxmlr:::.prototype_c4_visit_offsets(
      task$file, task$index,
      consume = function(batch) {
        # C4 numbers individual input files starting at 1. Shift *only* the
        # selected record IDs, according to source-file order, before writing.
        shifted <- as.double(batch$record_id) + task$record_id_offset
        if (any(shifted > .Machine$integer.max)) {
          stop("Selected record IDs exceed the canonical integer range.")
        }
        batch$record_id <- as.integer(shifted)
        attr(batch, "c4_native_profile") <- NULL
        parts <<- parts + 1L
        target <- file.path(task$path, sprintf("part-%06d.parquet", parts))
        arrow::write_parquet(batch, sink = target, compression = compression)
        count <<- count + length(unique(batch$record_id))
        rows <<- rows + nrow(batch)
        invisible(NULL)
      },
      batch_records = batch_records,
      batch_bytes = batch_bytes,
      .engine = "reader"
    )
  }
  if (count != task$records) {
    stop("C4 worker produced unexpected record count for ", task$file,
         call. = FALSE)
  }
  complete <- TRUE
  list(index = task$index_number, file = task$file, path = task$path,
       records = count, rows = rows, parquet_files = parts,
       materialize_s = .c4_parallel_clock() - t)
}

.c4_parallel_c1_one <- function(task, batch_records, compression, tag) {
  # C1 is used ONLY as a speed reference. This prototype's C1 path retains
  # its usual per-file record numbering; C4 additionally guarantees global
  # selected-record numbering across multiple input files.
  t <- .c4_parallel_clock()
  info <- marcxmlr:::.prototype_marcxml_to_parquet_filtered(
    file = task$file,
    output_dir = task$path,
    filter_tags = tag,
    record_filter = function(screen, record_ids) {
      record_ids %in% unique(screen$record_id)
    },
    batch_records = batch_records,
    compression = compression
  )
  list(index = task$index_number, file = task$file, path = task$path,
       records = as.integer(info$records[[1L]]),
       rows = as.double(info$rows[[1L]]),
       parquet_files = as.integer(info$parquet_files[[1L]]),
       materialize_s = .c4_parallel_clock() - t)
}

.c4_parallel_flatten <- function(results, staging) {
  next_id <- 1L
  for (result in results) {
    parts <- sort(list.files(result$path, pattern = "[.]parquet$",
                             full.names = TRUE))
    if (length(parts) != result$parquet_files) {
      stop("Missing Parquet parts for ", result$file, call. = FALSE)
    }
    for (part in parts) {
      target <- file.path(staging, sprintf("part-%06d.parquet", next_id))
      if (!file.rename(part, target)) {
        stop("Failed to consolidate Parquet part: ", part, call. = FALSE)
      }
      next_id <- next_id + 1L
    }
    unlink(result$path, recursive = TRUE, force = TRUE)
  }
  next_id - 1L
}

# Experimental entry point. `method = "c1"` exists only as a comparable
# per-file workload and is not intended as the new C1 production interface.
# `allow_repeated` supports testing eight logical inputs referencing one XML.
# An actual multi-file benchmark should use eight DISTINCT files.
.prototype_c4_multifile_to_parquet <- function(
    files, output_dir, tag = "856", workers = 2L,
    method = c("c4", "c1"), subfield = NULL, equals = NULL,
    batch_records = 500L, batch_bytes = 16 * 1024^2,
    compression = "snappy", allow_repeated = FALSE,
    tools_dir = .c4_parallel_tools_dir) {
  method <- match.arg(method)
  if (length(tag) != 1L || is.na(tag) || !grepl("^[0-9]{3}$", tag)) {
    stop("`tag` must contain exactly three digits.", call. = FALSE)
  }
  if (!is.null(subfield) &&
      (length(subfield) != 1L || is.na(subfield) ||
       nchar(subfield, type = "bytes") != 1L)) {
    stop("`subfield` must be one character.", call. = FALSE)
  }
  if (!is.null(equals) && is.null(subfield)) {
    stop("`equals` requires `subfield`.", call. = FALSE)
  }
  if (method == "c1" && (!is.null(subfield) || !is.null(equals))) {
    stop("C1 benchmark reference supports tag-presence filters only.",
         call. = FALSE)
  }
  valid_int <- function(x) is.numeric(x) && length(x) == 1L &&
    !is.na(x) && is.finite(x) && x >= 1 &&
    x <= .Machine$integer.max && x == floor(x)
  if (!valid_int(workers) || !valid_int(batch_records) ||
      !valid_int(batch_bytes)) {
    stop("`workers`, `batch_records`, `batch_bytes` must be positive integers.",
         call. = FALSE)
  }
  workers <- as.integer(workers)
  batch_records <- as.integer(batch_records)
  paths <- .c4_parallel_paths(files, allow_repeated = allow_repeated)
  # Filtered parallelism is deliberately file-level only. Do not silently
  # reduce a requested parallel run to one worker for a single source file.
  if (length(paths) == 1L && workers > 1L) {
    stop(
      "Parallel filtering requires at least two MARCXML input files; ",
      "use `workers = 1L` for a single file.",
      call. = FALSE
    )
  }
  workers <- min(workers, length(paths))
  if (!requireNamespace("marcxmlr", quietly = TRUE) ||
      !requireNamespace("arrow", quietly = TRUE) ||
      !requireNamespace("purrr", quietly = TRUE)) {
    stop("The installed marcxmlr, Arrow and purrr packages are required.",
         call. = FALSE)
  }
  if (workers > 1L &&
      (!requireNamespace("future", quietly = TRUE) ||
       !requireNamespace("future.mirai", quietly = TRUE) ||
       !requireNamespace("futurize", quietly = TRUE))) {
    stop("Parallel mode requires future, future.mirai and futurize.",
         call. = FALSE)
  }
  output_dir <- path.expand(output_dir)
  if (file.exists(output_dir)) {
    stop("Output directory already exists: ", output_dir, call. = FALSE)
  }
  parent <- dirname(output_dir)
  if (!dir.exists(parent)) {
    stop("Output parent directory does not exist: ", parent, call. = FALSE)
  }
  stage <- tempfile(".c4-multifile-stage-", tmpdir = parent)
  if (!dir.create(stage)) stop("Unable to create staging directory.",
                                call. = FALSE)
  committed <- FALSE
  on.exit(if (!committed) unlink(stage, recursive = TRUE, force = TRUE),
          add = TRUE)
  if (workers > 1L) {
    old_plan <- future::plan()
    on.exit(future::plan(old_plan), add = TRUE)
    future::plan(future.mirai::mirai_multisession, workers = workers)
  }
  first <- .c4_parallel_clock()
  index_s <- 0

  if (method == "c4") {
    # Compiler + fast UTF-8 checks are setup, not part of XML screening time.
    helper <- new.env(parent = baseenv())
    sys.source(file.path(tools_dir, "marcxmlr-offset-test.R"), envir = helper)
    for (file in paths) helper$.check_utf8(file)
    indexer <- helper$.compile_indexer(
      file.path(tools_dir, "record_offset_index.c")
    )
    t <- .c4_parallel_clock()
    scans <- .c4_parallel_map(paths, function(path) {
      .c4_parallel_screen_one(path, indexer, tag, subfield, equals)
    }, workers)
    index_s <- .c4_parallel_clock() - t
    counts <- vapply(scans, `[[`, integer(1L), "records")
    if (sum(as.double(counts)) > .Machine$integer.max) {
      stop("Selected records exceed integer `record_id` limits.",
           call. = FALSE)
    }
    offsets <- c(0, head(cumsum(as.double(counts)), -1L))
  } else {
    scans <- NULL
    counts <- NULL
    offsets <- rep(0, length(paths))
  }
  tasks <- lapply(seq_along(paths), function(i) {
    list(index_number = i, file = paths[[i]],
         index = if (method == "c4") scans[[i]]$index else NULL,
         records = if (method == "c4") counts[[i]] else NULL,
         record_id_offset = offsets[[i]],
         path = file.path(stage, sprintf("file-%06d", i)))
  })
  t <- .c4_parallel_clock()
  results <- .c4_parallel_map(tasks, function(task) {
    if (method == "c4") {
      .c4_parallel_write_one(task, batch_records, batch_bytes, compression)
    } else {
      .c4_parallel_c1_one(task, batch_records, compression, tag)
    }
  }, workers)
  materialize_s <- .c4_parallel_clock() - t
  t <- .c4_parallel_clock()
  n_parts <- .c4_parallel_flatten(results, stage)
  consolidate_s <- .c4_parallel_clock() - t
  if (!file.rename(stage, output_dir)) {
    stop("Unable to publish Parquet output directory.", call. = FALSE)
  }
  committed <- TRUE
  summary <- do.call(rbind, lapply(results, function(x) {
    data.frame(file_index = x$index, source_file = x$file,
               records = x$records, rows = x$rows,
               parquet_files = x$parquet_files,
               materialize_s = x$materialize_s,
               stringsAsFactors = FALSE)
  }))
  rownames(summary) <- NULL
  stopifnot(n_parts == sum(summary$parquet_files))
  list(method = method, workers = workers, files = length(paths),
       output_dir = normalizePath(output_dir, winslash = "/"),
       summary = summary,
       totals = c(records = sum(summary$records), rows = sum(summary$rows),
                  parquet_files = n_parts),
       timings = c(screen_s = index_s, materialize_s = materialize_s,
                   consolidate_s = consolidate_s,
                   total_s = .c4_parallel_clock() - first))
}
