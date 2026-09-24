.resolve_marcxml_files <- function(file) {
  valid <- is.character(file) &&
    length(file) >= 1L &&
    !anyNA(file) &&
    all(nzchar(file))

  if (!valid) {
    stop(
      "`file` must contain one or more non-empty, non-missing paths or glob patterns.",
      call. = FALSE
    )
  }

  resolved <- purrr::map(file, function(specification) {
    expanded <- path.expand(specification)

    if (file.exists(expanded)) {
      if (dir.exists(expanded)) {
        stop(
          sprintf(
            paste0(
              "MARCXML input is a directory: %s. ",
              "Use a glob such as %s instead."
            ),
            specification,
            shQuote(file.path(specification, "*.xml"))
          ),
          call. = FALSE
        )
      }

      return(normalizePath(
        expanded,
        winslash = "/",
        mustWork = TRUE
      ))
    }

    matches <- sort(Sys.glob(expanded))

    if (length(matches) == 0L) {
      stop(
        sprintf(
          "MARCXML input did not match any file: %s",
          specification
        ),
        call. = FALSE
      )
    }

    directory_matches <- matches[
      vapply(matches, dir.exists, logical(1L))
    ]
    if (length(directory_matches) > 0L) {
      stop(
        sprintf(
          "MARCXML glob matched a directory: %s",
          directory_matches[[1L]]
        ),
        call. = FALSE
      )
    }

    normalizePath(
      matches,
      winslash = "/",
      mustWork = TRUE
    )
  })

  resolved <- unlist(resolved, use.names = FALSE)

  if (anyDuplicated(resolved)) {
    duplicate_path <- resolved[duplicated(resolved)][[1L]]
    stop(
      sprintf(
        "MARCXML input resolves the same file more than once: %s",
        duplicate_path
      ),
      call. = FALSE
    )
  }

  resolved
}

.marcxml_internal_record_id_offset <- function() {
  offset <- getOption("marcxmlr.internal_record_id_offset", 0L)

  valid <- length(offset) == 1L &&
    is.numeric(offset) &&
    !is.na(offset) &&
    is.finite(offset) &&
    offset >= 0 &&
    offset <= .Machine$integer.max &&
    offset == floor(offset)

  if (!valid) {
    stop(
      "Internal MARCXML record-id offset is invalid.",
      call. = FALSE
    )
  }

  as.integer(offset)
}

.count_marcxml_collection_records <- function(file) {
  plan <- .native_marcxml_plan(
    file = file,
    mode = "stream"
  )

  if (identical(plan$status, "supported")) {
    on.exit(
      .native_marcxml_plan_close(plan),
      add = TRUE
    )

    info <- .native_marcxml_plan_info(plan)
    return(as.double(info$records_selected))
  }

  # Conservative fallback for inputs declined by the native planner. Count
  # complete record branches without materialising the catalogue in memory.
  state <- new.env(parent = emptyenv())
  state$seen_root <- FALSE
  state$records <- 0

  record_branch <- function(node) {
    if (!state$seen_root) {
      stop(
        "Expected a MARCXML `<collection>` document.",
        call. = FALSE
      )
    }

    state$records <- state$records + 1
    invisible(NULL)
  }

  start_element <- function(name, attributes, namespace, namespaces) {
    namespace_uri <- if (
      length(namespace) == 0L || is.na(namespace[[1L]])
    ) {
      ""
    } else {
      unname(namespace[[1L]])
    }

    if (!state$seen_root) {
      if (name != "collection") {
        stop(
          "Expected a MARCXML `<collection>` document.",
          call. = FALSE
        )
      }

      if (!namespace_uri %in% c("", .marcxml_namespace)) {
        stop(
          sprintf(
            "Document root uses namespace <%s>; expected <%s> or no namespace.",
            namespace_uri,
            .marcxml_namespace
          ),
          call. = FALSE
        )
      }

      state$seen_root <- TRUE
      return(invisible(NULL))
    }

    stop(
      "A MARCXML `<collection>` may contain only `<record>` elements.",
      call. = FALSE
    )
  }

  XML::xmlEventParse(
    file,
    handlers = list(.startElement = start_element),
    ignoreBlanks = FALSE,
    addContext = FALSE,
    useTagName = FALSE,
    asText = FALSE,
    trim = FALSE,
    useExpat = FALSE,
    replaceEntities = FALSE,
    validate = FALSE,
    saxVersion = 2L,
    branches = list(record = record_branch),
    useDotNames = TRUE
  )

  if (!state$seen_root) {
    stop(
      "The XML document has no MARCXML collection root.",
      call. = FALSE
    )
  }

  state$records
}

.prepare_multifile_output <- function(output_dir) {
  if (!is.character(output_dir) ||
      length(output_dir) != 1L ||
      is.na(output_dir) ||
      identical(output_dir, "")) {
    stop("`output_dir` must be one non-empty path.", call. = FALSE)
  }

  output_dir <- path.expand(output_dir)
  output_name <- basename(output_dir)
  output_parent <- dirname(output_dir)

  if (output_name %in% c("", ".", "..")) {
    stop("`output_dir` must name a new dataset directory.", call. = FALSE)
  }

  if (!dir.exists(output_parent)) {
    if (!dir.create(output_parent, recursive = TRUE)) {
      stop(
        sprintf(
          "Could not create output parent directory: %s",
          output_parent
        ),
        call. = FALSE
      )
    }
  }

  output_parent <- normalizePath(
    output_parent,
    winslash = "/",
    mustWork = TRUE
  )
  output_dir <- file.path(output_parent, output_name)

  if (file.exists(output_dir)) {
    stop(
      sprintf("`output_dir` already exists: %s", output_dir),
      call. = FALSE
    )
  }

  list(
    output_dir = output_dir,
    output_parent = output_parent,
    output_name = output_name
  )
}

.run_marcxml_file_task <- function(
  task,
  batch_records,
  compression
) {
  old_offset <- getOption(
    "marcxmlr.internal_record_id_offset",
    NULL
  )
  on.exit(
    options(
      marcxmlr.internal_record_id_offset = old_offset
    ),
    add = TRUE
  )

  options(
    marcxmlr.internal_record_id_offset =
      as.integer(task$record_id_offset)
  )

  if (isTRUE(task$verbose)) {
    message(sprintf(
      "Processing file %d/%d: %s",
      task$index,
      task$total,
      basename(task$file)
    ))
  }

  summary <- tryCatch(
    marcxml_to_parquet(
      file = task$file,
      output_dir = task$output_dir,
      batch_records = batch_records,
      workers = 1L,
      chunk_records = NULL,
      compression = compression,
      verbose = FALSE
    ),
    error = function(error) {
      stop(
        sprintf(
          "Failed while processing file %d/%d (%s): %s",
          task$index,
          task$total,
          basename(task$file),
          conditionMessage(error)
        ),
        call. = FALSE
      )
    }
  )

  if (isTRUE(task$verbose)) {
    message(sprintf(
      "Completed file %d/%d: %s (%s records)",
      task$index,
      task$total,
      basename(task$file),
      format(
        summary$records[[1L]],
        big.mark = ",",
        scientific = FALSE
      )
    ))
  }

  list(
    summary = summary,
    output_dir = task$output_dir
  )
}

.finalize_multifile_parquet_parts <- function(
  task_results,
  staging_dir
) {
  next_part <- 1L

  for (task_result in task_results) {
    source_dir <- task_result$output_dir
    source_files <- sort(list.files(
      source_dir,
      pattern = "\\.parquet$",
      full.names = TRUE
    ))

    if (length(source_files) == 0L) {
      stop(
        sprintf(
          "No Parquet files were produced for temporary dataset: %s",
          source_dir
        ),
        call. = FALSE
      )
    }

    target_ids <- next_part + seq_along(source_files) - 1L
    target_files <- file.path(
      staging_dir,
      sprintf("part-%06d.parquet", target_ids)
    )

    moved <- purrr::map2_lgl(
      source_files,
      target_files,
      file.rename
    )

    if (!all(moved)) {
      stop(
        sprintf(
          "Could not consolidate all Parquet files from: %s",
          source_dir
        ),
        call. = FALSE
      )
    }

    next_part <- next_part + length(source_files)
    unlink(source_dir, recursive = TRUE, force = TRUE)
  }

  next_part - 1L
}

.marcxml_to_parquet_multiple <- function(
  input_files,
  output_dir,
  batch_records,
  workers,
  compression,
  verbose
) {
  output <- .prepare_multifile_output(output_dir)

  staging_dir <- tempfile(
    pattern = paste0(
      ".",
      output$output_name,
      "-incomplete-"
    ),
    tmpdir = output$output_parent
  )

  if (!dir.create(staging_dir)) {
    stop(
      sprintf(
        "Could not create staging directory: %s",
        staging_dir
      ),
      call. = FALSE
    )
  }

  committed <- FALSE
  on.exit(
    if (!committed && dir.exists(staging_dir)) {
      unlink(staging_dir, recursive = TRUE, force = TRUE)
    },
    add = TRUE
  )

  file_count <- length(input_files)
  effective_workers <- min(workers, file_count)

  if (verbose) {
    message(sprintf(
      "Processing %d MARCXML files with %d worker(s).",
      file_count,
      effective_workers
    ))
  }

  if (effective_workers > 1L) {
    with(
      future::plan(
        future.mirai::mirai_multisession,
        workers = effective_workers
      ),
      local = TRUE
    )

    # File-level parallelism needs deterministic record-id ranges before
    # parsing starts. Count files in parallel as well, otherwise a sequential
    # preliminary pass can erase much of the benefit on large file sets.
    record_counts <- input_files |>
      purrr::map(function(input_file) {
        .count_marcxml_collection_records(input_file)
      }) |>
      futurize::futurize()
    record_counts <- unlist(
      record_counts,
      use.names = FALSE
    )

    total_records <- sum(record_counts)
    if (total_records > .Machine$integer.max) {
      stop(
        paste0(
          "The resolved MARCXML inputs contain more records than can be ",
          "represented by the canonical integer `record_id`."
        ),
        call. = FALSE
      )
    }

    record_id_offsets <- c(
      0,
      utils::head(cumsum(record_counts), -1L)
    )

    tasks <- purrr::map(
      seq_along(input_files),
      function(index) {
        list(
          file = input_files[[index]],
          record_id_offset = as.integer(
            record_id_offsets[[index]]
          ),
          output_dir = file.path(
            staging_dir,
            sprintf("file-%06d", index)
          ),
          index = index,
          total = file_count,
          verbose = verbose
        )
      }
    )

    task_results <- tasks |>
      purrr::map(function(task) {
        .run_marcxml_file_task(
          task = task,
          batch_records = batch_records,
          compression = compression
        )
      }) |>
      futurize::futurize()
  } else {
    # In sequential mode the next offset is known as soon as one file
    # completes, so no extra record-count pass is needed.
    next_offset <- 0
    task_results <- vector("list", file_count)

    for (index in seq_along(input_files)) {
      task <- list(
        file = input_files[[index]],
        record_id_offset = as.integer(next_offset),
        output_dir = file.path(
          staging_dir,
          sprintf("file-%06d", index)
        ),
        index = index,
        total = file_count,
        verbose = verbose
      )

      task_results[[index]] <- .run_marcxml_file_task(
        task = task,
        batch_records = batch_records,
        compression = compression
      )

      records <- as.double(
        task_results[[index]]$summary$records[[1L]]
      )
      next_offset <- next_offset + records

      if (next_offset > .Machine$integer.max) {
        stop(
          paste0(
            "The resolved MARCXML inputs contain more records than can be ",
            "represented by the canonical integer `record_id`."
          ),
          call. = FALSE
        )
      }
    }
  }

  summaries <- purrr::map(
    task_results,
    "summary"
  )
  summary <- purrr::list_rbind(summaries)

  parquet_files <- .finalize_multifile_parquet_parts(
    task_results = task_results,
    staging_dir = staging_dir
  )

  if (parquet_files != sum(summary$parquet_files)) {
    stop(
      "Internal Parquet file count changed while consolidating inputs.",
      call. = FALSE
    )
  }

  if (!file.rename(staging_dir, output$output_dir)) {
    stop(
      sprintf(
        "Could not finalize the dataset directory: %s",
        output$output_dir
      ),
      call. = FALSE
    )
  }

  committed <- TRUE
  final_output <- normalizePath(
    output$output_dir,
    winslash = "/",
    mustWork = TRUE
  )
  summary$output_dir <- final_output

  if (verbose) {
    message(sprintf(
      paste0(
        "Processed %s MARCXML file(s), %s record(s); ",
        "wrote %s Parquet file(s)."
      ),
      format(file_count, big.mark = ","),
      format(
        sum(summary$records),
        big.mark = ",",
        scientific = FALSE
      ),
      format(
        sum(summary$parquet_files),
        big.mark = ",",
        scientific = FALSE
      )
    ))
  }

  invisible(summary)
}
