# Run after installing this development version:
# Rscript -e 'source(system.file("benchmarks", "benchmark-native.R", package="marcxmlr"))'
# Optional: MARCXML_BENCH_FILE=/path/to/public.xml and MARCXML_BENCH_REPS=3
# Optional: MARCXML_REFERENCE_DIR=/path/to/unmodified/marcxmlr/checkout
# Reports same-machine medians; refuses to report speedups without exact parity.
library(marcxmlr)
local({
  old <- options(marcxmlr.native = TRUE)
  on.exit(options(old))
  reference_dir <- Sys.getenv("MARCXML_REFERENCE_DIR")
  oracle <- asNamespace("marcxmlr")
  if (nzchar(reference_dir)) {
    sources <- list.files(file.path(reference_dir, "R"), "\\.R$", full.names = TRUE)
    stopifnot(length(sources) > 0L)
    oracle <- new.env(parent = globalenv())
    for (path in sources) sys.source(path, envir = oracle)
    cat("Reference: source checkout", normalizePath(reference_dir), "\n")
  } else cat("Reference: R parser with current shared extraction code\n")
  file <- Sys.getenv("MARCXML_BENCH_FILE")
  reps <- as.integer(Sys.getenv("MARCXML_BENCH_REPS", "3"))
  stopifnot(length(reps) == 1L, !is.na(reps), reps > 0L)
  if (!nzchar(file)) {
    fixture <- system.file("extdata", "example-marcxml.xml", package = "marcxmlr")
    records <- marcxmlr:::.extract_marcxml_record_texts(fixture, Inf)
    file <- tempfile(fileext = ".xml")
    on.exit(unlink(file), add = TRUE)
    writeLines(c('<collection xmlns="http://www.loc.gov/MARC21/slim">',
                 rep(records, 1000L), '</collection>'), file, useBytes = TRUE)
    cat("Input: 2,000 synthetic records repeated from the bundled example\n")
  } else {
    cat("Input:", basename(file), "\n")
  }
  texts <- marcxmlr:::.extract_marcxml_record_texts(file, Inf)
  ids <- seq_along(texts)
  measure <- function(fun, native) {
    options(marcxmlr.native = native)
    value <- fun() # warm up both paths
    elapsed <- replicate(reps, {
      gc()
      unname(system.time(value <- fun())[["elapsed"]])
    })
    list(value = value, seconds = median(elapsed))
  }
  for (phase in c("parse_records", "read_marcxml")) {
    fun <- if (phase == "parse_records") {
      function() marcxmlr:::.parse_marcxml_text_chunk(texts, ids)
    } else function() read_marcxml(file)
    reference_fun <- if (phase == "parse_records") {
      function() oracle$.parse_marcxml_text_chunk(texts, ids)
    } else function() oracle$read_marcxml(file)
    ref <- measure(reference_fun, FALSE)
    native <- measure(fun, TRUE)
    stopifnot(identical(native$value, ref$value))
    print(data.frame(phase = phase, records = length(ids), rows = nrow(ref$value),
                     reference_seconds = ref$seconds, native_seconds = native$seconds,
                     speedup = ref$seconds / native$seconds, identical = TRUE))
  }
  cat(R.version.string, "\n")
  print(Sys.info()[c("sysname", "machine")])
})
