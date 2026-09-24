#!/usr/bin/env Rscript

# Development benchmark for the MARCXML writer hot path.
#
# Run from the package root, for example:
#
#   Rscript tools/benchmark-writer.R /path/to/catalogue.xml
#   Rscript tools/benchmark-writer.R /path/to/catalogue.xml \
#     --repeats=5 --sizes=1,100,1000,10000,all --pretty=true
#
# This deliberately benchmarks serialization only. Parsing the source XML,
# diagnostics, public write_marcxml() argument handling, sharding and staged
# output commits are outside the timed regions.

usage <- function(status = 0L) {
  cat(
    paste0(
      "Usage:\n",
      "  Rscript tools/benchmark-writer.R INPUT.xml [options]\n\n",
      "Options:\n",
      "  --repeats=N          Timed repetitions per case (default: 5)\n",
      "  --sizes=SPEC         Comma-separated record counts and/or 'all'\n",
      "                       (default: 1,100,1000,10000,all)\n",
      "  --pretty=true|false  Benchmark formatted XML (default: true)\n",
      "  --reference-max=N    Skip the slow R reference writer above N\n",
      "                       records (default: 5000)\n",
      "  --verify-max=N       Skip read-back verification above N records\n",
      "                       (default: 5000)\n",
      "  --output=FILE        CSV result path (default: temporary file)\n",
      "  --help               Show this help\n"
    )
  )
  quit(save = "no", status = status)
}

parse_bool <- function(x, name) {
  value <- tolower(x)
  if (value %in% c("true", "t", "1", "yes", "y")) {
    return(TRUE)
  }
  if (value %in% c("false", "f", "0", "no", "n")) {
    return(FALSE)
  }
  stop(sprintf("%s must be true or false.", name), call. = FALSE)
}

parse_positive_integer <- function(x, name) {
  value <- suppressWarnings(as.numeric(x))
  if (length(value) != 1L || is.na(value) || !is.finite(value) ||
      value < 1 || value != floor(value) || value > .Machine$integer.max) {
    stop(sprintf("%s must be a positive whole number.", name), call. = FALSE)
  }
  as.integer(value)
}

parse_args <- function(args) {
  if (length(args) == 0L || "--help" %in% args) {
    usage(if (length(args) == 0L) 1L else 0L)
  }

  positional <- args[!startsWith(args, "--")]
  if (length(positional) != 1L) {
    stop("Provide exactly one INPUT.xml path.", call. = FALSE)
  }

  out <- list(
    input = positional[[1L]],
    repeats = 5L,
    sizes = "1,100,1000,10000,all",
    pretty = TRUE,
    reference_max = 5000L,
    verify_max = 5000L,
    output = tempfile("marcxmlr-writer-benchmark-", fileext = ".csv")
  )

  options <- args[startsWith(args, "--")]
  for (arg in options) {
    if (identical(arg, "--help")) {
      next
    }

    bits <- strsplit(sub("^--", "", arg), "=", fixed = TRUE)[[1L]]
    if (length(bits) != 2L || bits[[2L]] == "") {
      stop(sprintf("Invalid option: %s", arg), call. = FALSE)
    }

    key <- bits[[1L]]
    value <- bits[[2L]]

    if (identical(key, "repeats")) {
      out$repeats <- parse_positive_integer(value, "--repeats")
    } else if (identical(key, "sizes")) {
      out$sizes <- value
    } else if (identical(key, "pretty")) {
      out$pretty <- parse_bool(value, "--pretty")
    } else if (identical(key, "reference-max")) {
      out$reference_max <- parse_positive_integer(value, "--reference-max")
    } else if (identical(key, "verify-max")) {
      out$verify_max <- parse_positive_integer(value, "--verify-max")
    } else if (identical(key, "output")) {
      out$output <- value
    } else {
      stop(sprintf("Unknown option: --%s", key), call. = FALSE)
    }
  }

  out
}

resolve_sizes <- function(spec, n_records) {
  pieces <- trimws(strsplit(spec, ",", fixed = TRUE)[[1L]])
  if (length(pieces) == 0L || any(pieces == "")) {
    stop("--sizes must contain at least one record count or 'all'.", call. = FALSE)
  }

  sizes <- integer()
  for (piece in pieces) {
    if (tolower(piece) == "all") {
      sizes <- c(sizes, n_records)
    } else {
      sizes <- c(sizes, parse_positive_integer(piece, "--sizes"))
    }
  }

  sizes <- unique(sizes[sizes <= n_records])
  if (length(sizes) == 0L) {
    stop("None of the requested --sizes fit the input catalogue.", call. = FALSE)
  }

  sort(sizes)
}

median_elapsed <- function(fun, repeats, warmup = TRUE) {
  if (isTRUE(warmup)) {
    fun()
  }

  times <- numeric(repeats)
  for (i in seq_len(repeats)) {
    gc(FALSE)
    times[[i]] <- unname(system.time(fun())[["elapsed"]])
  }
  stats::median(times)
}

median_file_elapsed <- function(fun, repeats, warmup = TRUE) {
  run_once <- function() {
    path <- tempfile("marcxmlr-writer-bench-", fileext = ".xml")
    on.exit(unlink(path, force = TRUE), add = TRUE)
    fun(path)
    if (!file.exists(path)) {
      stop("Timed writer did not create its output file.", call. = FALSE)
    }
    invisible(NULL)
  }

  median_elapsed(run_once, repeats = repeats, warmup = warmup)
}

safe_ratio <- function(a, b) {
  if (is.na(a) || is.na(b) || b <= 0) {
    return(NA_real_)
  }
  a / b
}

args <- parse_args(commandArgs(trailingOnly = TRUE))

if (!file.exists(args$input)) {
  stop(sprintf("Input file does not exist: %s", args$input), call. = FALSE)
}

if (!requireNamespace("devtools", quietly = TRUE)) {
  stop("This development benchmark requires the devtools package.", call. = FALSE)
}

# Load the current working tree, including its compiled native library. This is
# intentionally done before any timing begins.
devtools::load_all(".", quiet = TRUE, helpers = FALSE)

ns <- asNamespace("marcxmlr")
reference_writer <- get(".writer_write_collection_reference", envir = ns)
native_writer <- get(".writer_write_collection_native", envir = ns)
native_columns <- get(".writer_native_columns", envir = ns)
native_symbol <- get("C_marcxml_write_collection", envir = ns)

input <- normalizePath(args$input, winslash = "/", mustWork = TRUE)
cat(sprintf("Reading canonical input once: %s\n", input))
read_time <- system.time({
  x <- marcxmlr::read_marcxml(input)
})[["elapsed"]]

record_ids <- sort(unique(as.integer(x$record_id)))
n_records <- length(record_ids)
if (n_records == 0L) {
  stop("Input contains no MARC records.", call. = FALSE)
}

sizes <- resolve_sizes(args$sizes, n_records)
cat(sprintf(
  "Loaded %s records / %s canonical rows in %.3f s.\n",
  format(n_records, big.mark = ","),
  format(nrow(x), big.mark = ","),
  read_time
))
cat(sprintf(
  "Benchmarking record counts: %s; repeats: %d; pretty: %s\n\n",
  paste(format(sizes, big.mark = ","), collapse = ", "),
  args$repeats,
  if (args$pretty) "TRUE" else "FALSE"
))

results <- vector("list", length(sizes))

for (k in seq_along(sizes)) {
  n <- sizes[[k]]
  ids <- record_ids[seq_len(n)]
  keep <- as.integer(x$record_id) %in% ids
  x_n <- x[keep, , drop = FALSE]

  cat(sprintf(
    "[%d/%d] %s records / %s rows\n",
    k,
    length(sizes),
    format(n, big.mark = ","),
    format(nrow(x_n), big.mark = ",")
  ))

  prep_time <- median_elapsed(
    function() native_columns(x_n, ids),
    repeats = args$repeats
  )
  columns <- native_columns(x_n, ids)

  c_time <- median_file_elapsed(
    function(path) {
      .Call(native_symbol, columns, path, args$pretty)
    },
    repeats = args$repeats
  )

  native_total <- median_file_elapsed(
    function(path) {
      native_writer(x_n, ids, path, args$pretty)
    },
    repeats = args$repeats
  )

  reference_time <- NA_real_
  if (n <= args$reference_max) {
    reference_time <- median_file_elapsed(
      function(path) {
        reference_writer(x_n, ids, path, args$pretty)
      },
      repeats = args$repeats
    )
  }

  # One untimed native output is used for file-size measurement and, for
  # moderate cases, read-back verification. The deliberately slow reference
  # implementation is not invoked above --reference-max.
  native_file <- tempfile("marcxmlr-native-", fileext = ".xml")
  native_writer(x_n, ids, native_file, args$pretty)
  native_bytes <- unname(file.info(native_file)$size)

  reference_file <- NA_character_
  reference_bytes <- NA_real_
  semantic_equal <- NA
  input_roundtrip_equal <- NA

  if (n <= args$reference_max) {
    reference_file <- tempfile("marcxmlr-reference-", fileext = ".xml")
    reference_writer(x_n, ids, reference_file, args$pretty)
    reference_bytes <- unname(file.info(reference_file)$size)
  }

  if (n <= args$verify_max) {
    native_roundtrip <- marcxmlr::read_marcxml(native_file)
    input_roundtrip_equal <- identical(x_n, native_roundtrip)

    if (!is.na(reference_file)) {
      reference_roundtrip <- marcxmlr::read_marcxml(reference_file)
      semantic_equal <- identical(reference_roundtrip, native_roundtrip)
    }
  }

  unlink(native_file, force = TRUE)
  if (!is.na(reference_file)) {
    unlink(reference_file, force = TRUE)
  }

  results[[k]] <- data.frame(
    records = n,
    rows = nrow(x_n),
    pretty = args$pretty,
    repeats = args$repeats,
    reference_s = reference_time,
    native_total_s = native_total,
    native_prepare_s = prep_time,
    native_c_s = c_time,
    native_speedup_vs_reference = safe_ratio(reference_time, native_total),
    prepare_share_of_native = safe_ratio(prep_time, native_total),
    reference_bytes = reference_bytes,
    native_bytes = native_bytes,
    semantic_equal = semantic_equal,
    input_roundtrip_equal = input_roundtrip_equal,
    stringsAsFactors = FALSE
  )

  cat(sprintf(
    paste0(
      "  reference: %s s | native total: %.4f s | prepare: %.4f s | C: %.4f s\n",
      "  semantic equal: %s | input round-trip identical: %s\n\n"
    ),
    if (is.na(reference_time)) "skipped" else sprintf("%.4f", reference_time),
    native_total,
    prep_time,
    c_time,
    semantic_equal,
    input_roundtrip_equal
  ))
}

result <- do.call(rbind, results)
utils::write.csv(result, args$output, row.names = FALSE)

cat("Results:\n")
print(result, row.names = FALSE, digits = 4)
cat(sprintf("\nCSV: %s\n", normalizePath(args$output, winslash = "/", mustWork = TRUE)))
