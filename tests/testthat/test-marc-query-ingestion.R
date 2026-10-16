# Permanent regression tests for the new public MARC-aware C4 ingestion paths.
# Requires the bundled GPO fixture; parallel checks are deliberately opt-in.

query_test_file <- function() {
  system.file("extdata", "gpo-cgp-part00-sample.xml",
              package = "marcxmlr", mustWork = TRUE)
}

query_test_require_expat <- function(file) {
  probe <- try(marcxmlr:::.c4_screen_query_file(file, marc_has("001")),
               silent = TRUE)
  if (inherits(probe, "try-error")) {
    if (grepl("requires Expat support", as.character(probe), fixed = TRUE)) {
      testthat::skip("Expat support was not enabled when building marcxmlr")
    }
    stop(as.character(probe))
  }
  invisible(TRUE)
}

query_test_spec <- function(file) {
  full <- read_marcxml(file)
  values <- full$value[full$tag == "856" & full$subfield_code == "u"]
  values <- values[!is.na(values) & nzchar(values)]
  testthat::skip_if(length(values) == 0L, "Fixture contains no 856$u value")
  # AND combines predicates across records, never canonical rows.
  # OR, NOT, exact and literal substring matching are also exercised.
  query <- (marc_has("650") & marc_has("856", subfield = "u")) |
    (marc_has("856", subfield = "u", equals = values[[1L]]) &
       !marc_has("999"))
  list(full = full, query = query, url = values[[1L]])
}

query_test_expected <- function(full, query) {
  result <- marc_filter_records(full, query)
  ids <- unique(result$record_id)
  result$record_id <- as.integer(match(result$record_id, ids))
  rownames(result) <- NULL
  result
}

query_test_parquet <- function(path) {
  parts <- sort(list.files(path, pattern = "[.]parquet$", recursive = TRUE,
                           full.names = TRUE))
  testthat::expect_gt(length(parts), 0L)
  purrr::list_rbind(lapply(parts, arrow::read_parquet))
}

testthat::test_that("native XML MARC queries match complete tibble records", {
  testthat::skip_if_not_installed("dplyr")
  file <- query_test_file()
  query_test_require_expat(file)
  spec <- query_test_spec(file)
  first_id <- spec$full$value[spec$full$tag == "001"][[1L]]
  queries <- list(
    tag = marc_has("650"),
    exact = marc_has("856", subfield = "u", equals = spec$url),
    contains = marc_has("856", subfield = "u",
                        contains = substr(spec$url, 1L, 5L)),
    control = marc_has("001", equals = first_id),
    not = !marc_has("856"),
    compound = spec$query,
    absent = marc_has("999") & marc_has("001"),
    negated_absent = !marc_has("777")
  )
  for (name in names(queries)) {
    expected <- query_test_expected(spec$full, queries[[name]])
    actual <- read_marcxml(file, filter = queries[[name]])
    testthat::expect_equal(sort_canonical(actual), sort_canonical(expected),
                           info = name)
    testthat::expect_identical(names(actual), canonical_columns, info = name)
  }
  testthat::expect_identical(
    read_marcxml(file, filter = marc_has("001"), n_max = 0L),
    marcxmlr:::.empty_marcxml()
  )
  testthat::expect_equal(
    sort_canonical(read_marcxml(file, filter = marc_has("856"))),
    sort_canonical(read_marcxml(file, filter_tag = "856"))
  )
})

testthat::test_that("new query arguments preserve old filtering restrictions", {
  file <- query_test_file()
  q <- marc_has("856")
  testthat::expect_error(read_marcxml(file, filter = q, filter_tag = "856"),
                         "cannot be combined")
  testthat::expect_error(read_marcxml(file, filter = q, workers = 2L),
                         "Parallel filtering")
  testthat::expect_error(read_marcxml(file, filter = q, chunk_records = 2L),
                         "chunk_records")
  testthat::expect_error(marc_has("650", equals = "x", contains = "y"),
                         "only one")
})

testthat::test_that("single-file native query streams complete records to Parquet", {
  testthat::skip_if_not_installed("arrow")
  file <- query_test_file()
  query_test_require_expat(file)
  spec <- query_test_spec(file)
  expected <- read_marcxml(file, filter = spec$query)
  out <- tempfile("query-ingestion-single-")
  on.exit(unlink(out, recursive = TRUE, force = TRUE), add = TRUE)
  info <- marcxml_to_parquet(file, out, filter = spec$query,
                             workers = 1L, batch_records = 2L,
                             verbose = FALSE)
  actual <- query_test_parquet(out)
  testthat::expect_equal(sort_canonical(actual), sort_canonical(expected))
  testthat::expect_equal(sum(info$records), length(unique(expected$record_id)))
  testthat::expect_identical(names(actual), canonical_columns)

  empty_out <- tempfile("query-ingestion-empty-")
  on.exit(unlink(empty_out, recursive = TRUE, force = TRUE), add = TRUE)
  marcxml_to_parquet(file, empty_out,
                     filter = marc_has("001", equals = "__marcxmlr_nonexistent_id__"),
                     verbose = FALSE)
  testthat::expect_identical(query_test_parquet(empty_out),
                             marcxmlr:::.empty_marcxml())
  testthat::expect_error(marcxml_to_parquet(
    file, tempfile("query-parallel-reject-"), filter = spec$query,
    workers = 2L, verbose = FALSE), "Parallel filtering")
})

testthat::test_that("multi-file native query streaming preserves global record IDs", {
  testthat::skip_if_not_installed("dplyr")
  testthat::skip_if_not_installed("arrow")
  file <- query_test_file()
  query_test_require_expat(file)
  spec <- query_test_spec(file)
  copy <- tempfile(fileext = ".xml")
  testthat::expect_true(file.copy(file, copy))
  on.exit(unlink(copy), add = TRUE)
  inputs <- c(file, copy)
  one <- read_marcxml(file, filter = spec$query)
  testthat::expect_gt(length(unique(one$record_id)), 0L)
  two <- one
  two$record_id <- as.integer(two$record_id + max(one$record_id))
  expected <- purrr::list_rbind(list(one, two))

  out <- tempfile("query-ingestion-multifile-")
  on.exit(unlink(out, recursive = TRUE, force = TRUE), add = TRUE)
  info <- marcxml_to_parquet(inputs, out, filter = spec$query,
                             workers = 1L, batch_records = 2L,
                             verbose = FALSE)
  actual <- query_test_parquet(out)
  testthat::expect_equal(sort_canonical(actual), sort_canonical(expected))
  testthat::expect_equal(sum(info$records), 2L * length(unique(one$record_id)))
  testthat::expect_equal(length(unique(actual$record_id)),
                         2L * length(unique(one$record_id)))

  ds <- arrow::open_dataset(out)
  downstream <- marc_has("856", subfield = "u") & !marc_has("777")
  from_arrow <- dplyr::collect(marc_filter_records(ds, downstream))
  from_tibble <- marc_filter_records(expected, downstream)
  testthat::expect_equal(sort_canonical(from_arrow), sort_canonical(from_tibble))
})

testthat::test_that("parallel multi-file MARC queries equal sequential results", {
  testthat::skip_if(Sys.getenv("RUN_MARCXML_PARALLEL_TESTS") != "true")
  testthat::skip_if_not_installed("arrow")
  testthat::skip_if_not_installed("future.mirai")
  testthat::skip_if_not_installed("futurize")
  testthat::skip_if_not_installed("mori")
  testthat::skip_if(future::availableCores() < 2L)
  file <- query_test_file()
  query_test_require_expat(file)
  query <- query_test_spec(file)$query
  copy <- tempfile(fileext = ".xml")
  testthat::expect_true(file.copy(file, copy))
  on.exit(unlink(copy), add = TRUE)
  files <- c(file, copy)

  sequential <- tempfile("query-ingestion-seq-")
  parallel <- tempfile("query-ingestion-par-")
  on.exit(unlink(sequential, recursive = TRUE, force = TRUE), add = TRUE)
  on.exit(unlink(parallel, recursive = TRUE, force = TRUE), add = TRUE)
  marcxml_to_parquet(files, sequential, filter = query,
                     workers = 1L, batch_records = 2L, verbose = FALSE)
  prior_plan <- future::plan()
  marcxml_to_parquet(files, parallel, filter = query,
                     workers = 2L, batch_records = 2L, verbose = FALSE)
  testthat::expect_true(isTRUE(all.equal(future::plan(), prior_plan)))
  testthat::expect_equal(sort_canonical(query_test_parquet(parallel)),
                         sort_canonical(query_test_parquet(sequential)))
})
