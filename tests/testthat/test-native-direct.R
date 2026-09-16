test_that("direct planner predicts and writes the canonical example exactly", {
  old <- options(
    marcxmlr.native = TRUE,
    marcxmlr.direct = TRUE
  )
  on.exit(options(old))

  file <- example_marcxml_file()
  reference <- reference_read(file)

  plan <- .native_marcxml_plan(file, mode = "read")
  on.exit(.native_marcxml_plan_close(plan), add = TRUE)

  expect_identical(plan$status, "supported")

  info <- .native_marcxml_plan_info(plan)
  expected_rows <- as.numeric(tabulate(reference$record_id))

  expect_identical(info$input_kind, "collection")
  expect_identical(info$records_total, 2)
  expect_identical(info$records_selected, 2)
  expect_identical(info$rows_selected, as.numeric(nrow(reference)))
  expect_identical(info$rows_per_record, expected_rows)

  direct <- purrr::map(seq_len(2L), function(record_id) {
    .native_marcxml_plan_record(
      plan,
      record_index = record_id,
      record_id = record_id
    )
  }) |>
    purrr::list_rbind()

  expect_identical(
    sort_canonical(direct),
    sort_canonical(reference)
  )
})

test_that("direct planner respects n_max without skipping document validation", {
  old <- options(marcxmlr.native = TRUE)
  on.exit(options(old))

  file <- example_marcxml_file()
  first <- reference_read(file, n_max = 1L)

  plan <- .native_marcxml_plan(
    file,
    mode = "read",
    n_max = 1L
  )
  on.exit(.native_marcxml_plan_close(plan), add = TRUE)

  info <- .native_marcxml_plan_info(plan)

  expect_identical(info$records_total, 2)
  expect_identical(info$records_selected, 1)
  expect_identical(info$rows_selected, as.numeric(nrow(first)))
  expect_identical(info$rows_per_record, as.numeric(nrow(first)))

  zero <- .native_marcxml_plan(
    file,
    mode = "read",
    n_max = 0L
  )
  on.exit(.native_marcxml_plan_close(zero), add = TRUE)

  zero_info <- .native_marcxml_plan_info(zero)
  expect_identical(zero_info$records_total, 2)
  expect_identical(zero_info$records_selected, 0)
  expect_identical(zero_info$rows_selected, 0)
  expect_length(zero_info$rows_per_record, 0L)
})

test_that("direct batch reader owns its plan and matches the reference", {
  old <- options(marcxmlr.native = TRUE)
  on.exit(options(old))

  file <- example_marcxml_file()
  reference <- reference_read(file)
  plan <- .native_marcxml_plan(file, mode = "stream")
  expect_identical(plan$status, "supported")

  reader <- .native_marcxml_direct_reader_open(plan)
  .native_marcxml_plan_close(plan)
  on.exit(.native_marcxml_direct_reader_close(reader), add = TRUE)

  first <- .native_marcxml_direct_reader_next(reader, 1L)
  second <- .native_marcxml_direct_reader_next(reader, 1L)
  done <- .native_marcxml_direct_reader_next(reader, 1L)

  expect_identical(first$records, 1L)
  expect_identical(first$first_record_id, 1L)
  expect_identical(second$records, 1L)
  expect_identical(second$first_record_id, 2L)
  expect_null(done)

  direct <- purrr::list_rbind(list(first$data, second$data))
  expect_identical(
    sort_canonical(direct),
    sort_canonical(reference)
  )
})

test_that("public sequential read prefers direct native and retains legacy fallback", {
  file <- example_marcxml_file()
  reference <- reference_read(file)

  old <- options(
    marcxmlr.native = TRUE,
    marcxmlr.direct = TRUE
  )
  on.exit(options(old))

  direct <- read_marcxml(file, workers = 1L)

  options(marcxmlr.direct = FALSE)
  legacy <- read_marcxml(file, workers = 1L)

  expect_identical(
    sort_canonical(direct),
    sort_canonical(reference)
  )
  expect_identical(
    sort_canonical(direct),
    sort_canonical(legacy)
  )
})

test_that("planner conservatively declines unsupported direct inputs", {
  old <- options(marcxmlr.native = TRUE)
  on.exit(options(old))

  standalone <- write_test_xml(
    '<record><leader>L</leader><controlfield tag="001">x</controlfield></record>'
  )

  read_plan <- .native_marcxml_plan(standalone, mode = "read")
  on.exit(.native_marcxml_plan_close(read_plan), add = TRUE)
  expect_identical(read_plan$status, "supported")
  expect_identical(.native_marcxml_plan_info(read_plan)$input_kind, "record")

  stream_plan <- .native_marcxml_plan(standalone, mode = "stream")
  expect_identical(stream_plan$status, "decline")

  dtd <- write_test_xml(
    paste0(
      '<!DOCTYPE collection [<!ENTITY e "x">]>',
      '<collection><record><leader>&e;</leader></record></collection>'
    )
  )
  dtd_plan <- .native_marcxml_plan(dtd, mode = "stream")
  expect_identical(dtd_plan$status, "decline")
})

test_that("direct Parquet matches legacy native and R/XML streaming", {
  skip_if_not_installed("XML")
  skip_if_not_installed("arrow")

  old <- options(
    marcxmlr.native = TRUE,
    marcxmlr.native_stream = TRUE,
    marcxmlr.direct = TRUE,
    marcxmlr.direct_parquet = TRUE
  )
  on.exit(options(old))

  input <- example_marcxml_file()
  outputs <- c(tempfile(), tempfile(), tempfile())
  on.exit(unlink(outputs, recursive = TRUE), add = TRUE)

  direct_summary <- marcxml_to_parquet(
    input,
    outputs[[1L]],
    batch_records = 1L,
    workers = 1L,
    verbose = FALSE
  )

  options(marcxmlr.direct_parquet = FALSE)
  legacy_summary <- marcxml_to_parquet(
    input,
    outputs[[2L]],
    batch_records = 1L,
    workers = 1L,
    verbose = FALSE
  )

  options(marcxmlr.native_stream = FALSE)
  fallback_summary <- marcxml_to_parquet(
    input,
    outputs[[3L]],
    batch_records = 1L,
    workers = 1L,
    verbose = FALSE
  )

  read_parts <- function(path) {
    files <- sort(list.files(
      path,
      pattern = "\\.parquet$",
      full.names = TRUE
    ))
    purrr::list_rbind(purrr::map(files, arrow::read_parquet))
  }

  direct <- read_parts(outputs[[1L]])
  legacy <- read_parts(outputs[[2L]])
  fallback <- read_parts(outputs[[3L]])

  expect_identical(sort_canonical(direct), sort_canonical(legacy))
  expect_identical(sort_canonical(direct), sort_canonical(fallback))
  expect_identical(
    sort_canonical(direct),
    sort_canonical(reference_read(input))
  )

  fields <- c("records", "rows", "batches", "parquet_files")
  expect_identical(direct_summary[fields], legacy_summary[fields])
  expect_identical(direct_summary[fields], fallback_summary[fields])
})

test_that("direct Parquet preserves an empty collection schema and summary", {
  skip_if_not_installed("XML")
  skip_if_not_installed("arrow")

  old <- options(
    marcxmlr.native = TRUE,
    marcxmlr.native_stream = TRUE,
    marcxmlr.direct = TRUE,
    marcxmlr.direct_parquet = TRUE
  )
  on.exit(options(old))

  input <- write_test_xml("<collection></collection>")
  output <- tempfile()
  on.exit(unlink(output, recursive = TRUE), add = TRUE)

  summary <- marcxml_to_parquet(
    input,
    output,
    batch_records = 10L,
    workers = 1L,
    verbose = FALSE
  )

  file <- list.files(output, pattern = "\\.parquet$", full.names = TRUE)
  result <- arrow::read_parquet(file[[1L]])

  expect_identical(names(result), canonical_columns)
  expect_identical(nrow(result), 0L)
  expect_identical(summary$records, 0L)
  expect_identical(summary$rows, 0)
  expect_identical(summary$batches, 0L)
  expect_identical(summary$parquet_files, 1L)
})
