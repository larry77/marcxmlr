test_that("public C4 in-memory filtering reproduces canonical selected records", {
  source_file <- system.file("extdata", "gpo-cgp-part00-sample.xml",
                             package = "marcxmlr")
  skip_if_not(nzchar(source_file))
  probe <- try(marcxmlr:::.c4_screen_file(
    source_file, "856", NULL, NULL), silent = TRUE)
  if (inherits(probe, "try-error")) {
    if (grepl("requires Expat support", as.character(probe), fixed = TRUE)) {
      skip("Expat offset support is not installed")
    }
    stop(as.character(probe))
  }

  full <- read_marcxml(source_file)
  ids <- unique(full$record_id[full$tag == "856"])
  expected <- full[full$record_id %in% ids, , drop = FALSE]
  expected$record_id <- as.integer(match(expected$record_id, ids))
  rownames(expected) <- NULL
  selected <- read_marcxml(source_file, filter_tag = "856")
  expect_identical(selected, expected)
  expect_identical(unique(selected$record_id), seq_along(ids))

  limited <- read_marcxml(source_file, filter_tag = "856", n_max = ids[[1L]])
  expect_identical(limited, expected[expected$record_id == 1L, , drop = FALSE])

  first_subfield <- full[full$record_id == ids[[1L]] &
                         full$tag == "856" & full$subfield_code == "u", ]
  skip_if_not(nrow(first_subfield) > 0L)
  url <- first_subfield$value[[1L]]
  ids_with_url <- unique(full$record_id[full$tag == "856" &
                                         full$subfield_code == "u" &
                                         full$value == url & !is.na(full$value)])
  expected_url <- full[full$record_id %in% ids_with_url, , drop = FALSE]
  expected_url$record_id <- as.integer(match(expected_url$record_id,
                                             ids_with_url))
  rownames(expected_url) <- NULL
  expect_identical(
    read_marcxml(source_file, filter_tag = "856",
                 filter_subfield = "u", filter_equals = url), expected_url
  )
  expect_identical(read_marcxml(source_file, filter_tag = "999"),
                   marcxmlr:::.empty_marcxml())
})

test_that("public filtering validates unsupported combinations", {
  file <- system.file("extdata", "gpo-cgp-part00-sample.xml",
                      package = "marcxmlr")
  expect_error(read_marcxml(file, filter_tag = "856", workers = 2L),
               "Parallel filtering")
  expect_error(read_marcxml(file, filter_subfield = "u"),
               "require `filter_tag`")
  expect_error(read_marcxml(file, filter_tag = "856", chunk_records = 2L),
               "chunk_records")
  expect_error(read_marcxml(file, filter_tag = "856", on_marc_error = "skip"),
               "does not support")
  expect_error(read_marcxml(file, filter_tag = "856", filter_equals = "x"),
               "requires `filter_subfield`")
  out <- tempfile("filtered-single-guard-")
  expect_error(marcxml_to_parquet(file, out, filter_tag = "856", workers = 2L),
               "Parallel filtering")
  expect_false(dir.exists(out))
})

test_that("public C4 Parquet filtering preserves global selected IDs", {
  skip_if_not_installed("arrow")
  skip_if_not_installed("future.mirai")
  source_file <- system.file("extdata", "gpo-cgp-part00-sample.xml",
                             package = "marcxmlr")
  probe <- try(marcxmlr:::.c4_screen_file(
    source_file, "856", NULL, NULL), silent = TRUE)
  if (inherits(probe, "try-error")) {
    if (grepl("requires Expat support", as.character(probe), fixed = TRUE)) {
      skip("Expat offset support is not installed")
    }
    stop(as.character(probe))
  }
  files <- c(tempfile(fileext = ".xml"), tempfile(fileext = ".xml"))
  stopifnot(all(file.copy(source_file, files)))
  on.exit(unlink(files), add = TRUE)
  one <- read_marcxml(files[[1L]], filter_tag = "856")
  two <- one
  two$record_id <- two$record_id + max(one$record_id)
  expected <- purrr::list_rbind(list(one, two))

  for (workers in c(1L, 2L)) {
    dest <- tempfile("c4-public-parquet-")
    on.exit(unlink(dest, recursive = TRUE, force = TRUE), add = TRUE)
    info <- marcxml_to_parquet(
      files, dest, filter_tag = "856", workers = workers,
      batch_records = 2L, verbose = FALSE
    )
    expect_equal(sum(info$records), 2L * length(unique(one$record_id)))
    parts <- sort(list.files(dest, pattern = "[.]parquet$", full.names = TRUE))
    actual <- purrr::list_rbind(lapply(parts, arrow::read_parquet))
    expect_identical(actual, expected)
    unlink(dest, recursive = TRUE, force = TRUE)
  }

  dest <- tempfile("c4-public-empty-")
  on.exit(unlink(dest, recursive = TRUE, force = TRUE), add = TRUE)
  info <- marcxml_to_parquet(files, dest, filter_tag = "999",
                             workers = 2L, verbose = FALSE)
  expect_equal(sum(info$records), 0)
  parts <- list.files(dest, pattern = "[.]parquet$", full.names = TRUE)
  expect_true(length(parts) > 0L)
  expect_identical(arrow::read_parquet(parts[[1L]]),
                   marcxmlr:::.empty_marcxml())
})
