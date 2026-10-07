recovery_collection <- function(malformed_xml = FALSE) {
  closing <- if (malformed_xml) character() else "</collection>"

  write_test_xml(c(
    '<collection xmlns="http://www.loc.gov/MARC21/slim">',
    '  <record>',
    '    <leader>00000nam a2200000 i 4500</leader>',
    '    <controlfield tag="001">good-1</controlfield>',
    '    <datafield tag="245" ind1="1" ind2="0">',
    '      <subfield code="a">First</subfield>',
    '    </datafield>',
    '  </record>',
    '  <record>',
    '    <leader>00000nam a2200000 i 4500</leader>',
    '    <controlfield tag="001">bad-2</controlfield>',
    '    <datafield tag="650" ind1=" " ind2="0" />',
    '  </record>',
    '  <record>',
    '    <leader>00000nam a2200000 i 4500</leader>',
    '    <controlfield tag="001">good-3</controlfield>',
    '    <datafield tag="245" ind1="1" ind2="0">',
    '      <subfield code="a">Third</subfield>',
    '    </datafield>',
    '  </record>',
    closing
  ))
}

test_that("read_marcxml can skip malformed MARC records with diagnostics", {
  input <- recovery_collection()
  report <- tempfile(fileext = ".csv")

  expect_warning(
    result <- read_marcxml(
      input,
      on_marc_error = "skip",
      error_report = report
    ),
    "Skipped 1 malformed MARC record"
  )

  expect_identical(unique(result$record_id), c(1L, 3L))
  expect_true(file.exists(report))

  problems <- utils::read.csv(report, stringsAsFactors = FALSE)

  expect_equal(nrow(problems), 1L)
  expect_equal(problems$source_record, 2L)
  expect_equal(problems$record_id, 2L)
  expect_equal(problems$control_number, "bad-2")
  expect_match(problems$reason, "without any `<subfield>`", fixed = TRUE)
  expect_match(problems$record_xml, "bad-2", fixed = TRUE)
})

test_that("read_marcxml recovery never suppresses malformed XML", {
  input <- recovery_collection(malformed_xml = TRUE)
  report <- tempfile(fileext = ".csv")

  expect_error(
    read_marcxml(
      input,
      on_marc_error = "skip",
      error_report = report
    )
  )

  expect_false(file.exists(report))
})

test_that("read_marcxml recovery writes an empty report for clean MARCXML", {
  report <- tempfile(fileext = ".csv")

  expect_no_warning(
    result <- read_marcxml(
      example_marcxml_file(),
      on_marc_error = "skip",
      error_report = report
    )
  )

  expect_gt(nrow(result), 0L)
  problems <- utils::read.csv(report, stringsAsFactors = FALSE)
  expect_equal(nrow(problems), 0L)
})

test_that("Parquet recovery skips malformed MARC records in bounded mode", {
  skip_if_not_installed("XML")
  skip_if_not_installed("arrow")

  input <- recovery_collection()
  output <- tempfile("marcxml-recovery-output-")
  report <- tempfile(fileext = ".csv")

  expect_warning(
    summary <- marcxml_to_parquet(
      input,
      output_dir = output,
      batch_records = 1L,
      workers = 1L,
      verbose = FALSE,
      on_marc_error = "skip",
      error_report = report
    ),
    "Skipped 1 malformed MARC record"
  )

  expect_identical(summary$source_records, 3L)
  expect_identical(summary$records, 2L)
  expect_identical(summary$skipped_records, 1L)
  expect_true(dir.exists(output))
  expect_true(file.exists(report))

  parts <- sort(list.files(
    output,
    pattern = "\\.parquet$",
    full.names = TRUE
  ))
  result <- purrr::map(parts, arrow::read_parquet) |>
    purrr::list_rbind()

  expect_identical(unique(result$record_id), c(1L, 3L))

  problems <- utils::read.csv(report, stringsAsFactors = FALSE)
  expect_equal(nrow(problems), 1L)
  expect_equal(problems$source_record, 2L)
  expect_equal(problems$control_number, "bad-2")
})

test_that("Parquet recovery publishes nothing after malformed XML", {
  skip_if_not_installed("XML")
  skip_if_not_installed("arrow")

  input <- recovery_collection(malformed_xml = TRUE)
  output <- tempfile("marcxml-recovery-output-")
  report <- tempfile(fileext = ".csv")

  expect_error(
    marcxml_to_parquet(
      input,
      output_dir = output,
      batch_records = 1L,
      workers = 1L,
      verbose = FALSE,
      on_marc_error = "skip",
      error_report = report
    )
  )

  expect_false(file.exists(output))
  expect_false(file.exists(report))
})

test_that("recovery mode is deliberately conservative about execution mode", {
  report <- tempfile(fileext = ".csv")

  expect_error(
    read_marcxml(
      example_marcxml_file(),
      workers = 2L,
      on_marc_error = "skip",
      error_report = report
    ),
    "requires `workers = 1`",
    fixed = TRUE
  )

  skip_if_not_installed("XML")
  skip_if_not_installed("arrow")

  output <- tempfile("marcxml-recovery-output-")

  expect_error(
    marcxml_to_parquet(
      example_marcxml_file(),
      output_dir = output,
      chunk_records = 1L,
      on_marc_error = "skip",
      error_report = report,
      verbose = FALSE
    ),
    "requires `chunk_records = NULL`",
    fixed = TRUE
  )
})

test_that("native recovery planner skips malformed source records directly", {
  input <- recovery_collection()
  plan <- .native_marcxml_recovery_plan(input, mode = "read")

  expect_identical(plan$status, "supported")
  on.exit(.native_marcxml_recovery_plan_close(plan), add = TRUE)

  info <- .native_marcxml_recovery_plan_info(plan)
  expect_equal(info$source_records_selected, 3)
  expect_equal(info$records_valid, 2)
  expect_equal(info$skipped_records, 1)
  expect_equal(info$source_record_per_valid, c(1, 3))
  expect_equal(info$diagnostics$source_record, 2)
  expect_identical(info$diagnostics$reason_code, 9L)

  reader <- .native_marcxml_recovery_reader_open(plan)
  on.exit(.native_marcxml_recovery_reader_close(reader), add = TRUE)

  batch <- .native_marcxml_recovery_reader_next(reader, batch_records = 2L)
  expect_identical(unique(batch$data$record_id), c(1L, 3L))
  expect_identical(batch$records, 2L)
  expect_null(.native_marcxml_recovery_reader_next(reader, batch_records = 1L))
})

test_that("recovery mode does not fall back to record-by-record R parsing", {
  input <- recovery_collection()
  report <- tempfile(fileext = ".csv")
  old <- options(marcxmlr.native = FALSE)
  on.exit(options(old), add = TRUE)

  expect_error(
    read_marcxml(
      input,
      on_marc_error = "skip",
      error_report = report
    ),
    "native",
    ignore.case = TRUE
  )

  expect_false(file.exists(report))
})
