# Opt-in C4 experiments only: the standard unfiltered code is untouched.

test_that("C4 stream engine and native binding agree exactly with C4 DOM", {
  skip_on_cran()
  f <- system.file("extdata", "gpo-cgp-part00-sample.xml", package = "marcxmlr")
  skip_if_not(nzchar(f))
  offsets <- data.frame(
    start_byte = c(839544, 1005937, 2256667, 2352970),
    end_byte = c(846556, 1014950, 2261519, 2358452)
  )
  run <- marcxmlr:::.prototype_c4_native_read_offsets
  base <- run(f, offsets, batch_records = 2L,
              .engine = "dom", .binding = "purrr")
  for (engine in c("dom", "reader")) {
    for (binding in c("purrr", "native")) {
      got <- run(f, offsets, batch_records = 2L,
                 .engine = engine, .binding = binding)
      expect_identical(got, base)
      expect_identical(unique(got$record_id), 1:4)
    }
  }
  prof <- run(f, offsets, batch_records = 2L,
              .engine = "reader", .binding = "native", .profile = TRUE)
  expect_identical(prof$canonical, base)
  expect_true(all(is.finite(prof$native_profile)))
  expect_equal(prof$batches, 2L)
  expect_true("r_bind_s" %in% names(prof$r_profile))

  empty <- offsets[0, , drop = FALSE]
  expect_identical(run(f, empty, .engine = "reader", .binding = "native"),
                   marcxmlr:::.empty_marcxml())
})

test_that("C4 stream validates selected records and ignores invalid discarded ones", {
  skip_on_cran()
  good <- '<record xmlns="http://www.loc.gov/MARC21/slim"><leader>00000nam a2200000 a 4500</leader></record>'
  bad <- '<record xmlns="http://www.loc.gov/MARC21/slim"><bogus/></record>'
  doc <- paste0('<collection xmlns="http://www.loc.gov/MARC21/slim">',
                bad, good, '</collection>')
  file <- tempfile(fileext = ".xml")
  on.exit(unlink(file), add = TRUE)
  writeBin(charToRaw(doc), file)
  range <- function(what) {
    a <- regexpr(what, doc, fixed = TRUE)[[1L]] - 1L
    data.frame(start_byte = a, end_byte = a + nchar(what, type = "bytes"))
  }
  parser <- marcxmlr:::.prototype_c4_native_read_offsets
  expect_identical(parser(file, range(good), .engine = "reader", .binding = "native"),
                   parser(file, range(good), .engine = "dom", .binding = "purrr"))
  expect_error(parser(file, range(bad), .engine = "reader"), "valid MARCXML")
})

test_that("C4 reader engine preserves bounded Parquet output", {
  skip_on_cran()
  skip_if_not_installed("arrow")
  good <- '<record xmlns="http://www.loc.gov/MARC21/slim"><leader>00000nam a2200000 a 4500</leader></record>'
  file <- tempfile(fileext = ".xml")
  writeBin(charToRaw(paste0('<collection>', good, good, '</collection>')), file)
  on.exit(unlink(file), add = TRUE)
  beg <- nchar('<collection>', type = "bytes")
  len <- nchar(good, type = "bytes")
  offsets <- data.frame(start_byte = c(beg, beg + len),
                        end_byte = c(beg + len, beg + 2 * len))
  out <- tempfile("c4-stream-")
  on.exit(unlink(out, recursive = TRUE, force = TRUE), add = TRUE)
  info <- marcxmlr:::.prototype_c4_native_to_parquet_offsets(
    file, offsets, out, batch_records = 1L, .engine = "reader")
  expect_equal(info$rows, 2)
  expect_equal(info$records, 2)
  expect_equal(info$parquet_files, 2)
  part_files <- sort(list.files(out, pattern = "[.]parquet$", full.names = TRUE))
  restored_ids <- unlist(lapply(part_files, function(p)
    arrow::read_parquet(p)$record_id), use.names = FALSE)
  expect_identical(restored_ids, 1:2)
})
