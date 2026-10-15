test_that("opt-in native filtering profile preserves canonical output", {
  skip_on_os("windows")
  skip_if_not(file.exists("/proc/self/status"))
  file <- system.file("extdata", "example-marcxml.xml", package = "marcxmlr")
  full <- read_marcxml(file)

  callback <- function(x, record_ids) {
    record_ids %in% x$record_id[x$subfield_code == "a" & x$value == "Metadata"]
  }
  p <- .prototype_profile_marcxml_filtered(
    file, filter_tags = "650", record_filter = callback,
    screen_batch_records = 1L, batch_records = 1L
  )
  expect_identical(p$result, full[full$record_id == 1L, , drop = FALSE])
  expect_true(all(is.finite(p$timings)))
  expect_true(all(p$timings >= 0))
  expect_identical(unname(p$counts[["selected_records"]]), 1)
  expect_identical(unname(p$counts[["source_records_scanned"]]), 2)
  expect_true(p$counts[["screen_batches"]] >= 2)
  expect_true(p$timings[["screen_native_s"]] >= p$timings[["screen_validate_s"]])
  expect_true(p$timings[["second_native_s"]] >= p$timings[["second_write_s"]])

  # Turning the profiler on must not change the regular prototype output.
  ordinary <- .prototype_read_marcxml_filtered(
    file, filter_tags = "650", record_filter = callback,
    screen_batch_records = 1L
  )
  expect_identical(p$result, ordinary)
})

test_that("profiling supports zero selected records", {
  skip_on_os("windows")
  skip_if_not(file.exists("/proc/self/status"))
  file <- system.file("extdata", "example-marcxml.xml", package = "marcxmlr")
  p <- .prototype_profile_marcxml_filtered(
    file, filter_tags = "650",
    record_filter = function(x, record_ids) rep(FALSE, length(record_ids)),
    screen_batch_records = 1L
  )
  expect_identical(p$result, .empty_marcxml())
  expect_equal(p$counts[["selected_records"]], 0)
  expect_equal(p$timings[["second_native_s"]], 0)
})
