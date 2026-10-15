# Opt-in experimental C4 direct-offset native batch writer.
# The ordinary public parsing paths are not modified by this experiment.

test_that("C4 native selected offsets reconstruct the exact canonical table", {
  skip_on_cran()
  skip_on_os("windows")
  skip_if_not(nzchar(Sys.which("cc")))
  helper <- testthat::test_path("..", "..", "tools", "c4-offset", "record_offset_index.c")
  skip_if_not(file.exists(helper))
  env <- new.env(parent = globalenv())
  sys.source(file.path(dirname(helper), "marcxmlr-offset-test.R"), envir = env)
  indexer <- env$.compile_indexer(helper)
  source_file <- system.file("extdata", "gpo-cgp-part00-sample.xml",
                             package = "marcxmlr")
  skip_if_not(nzchar(source_file))
  index_file <- tempfile(fileext = ".tsv")
  log_file <- tempfile(fileext = ".log")
  on.exit(unlink(c(index_file, log_file)), add = TRUE)
  status <- suppressWarnings(system2(
    indexer,
    shQuote(c(source_file, "856", "-", "-")),
    stdout = index_file, stderr = log_file
  ))
  expect_identical(as.integer(status), 0L)
  offsets <- utils::read.delim(index_file)
  expect_equal(nrow(offsets), 4L)
  got <- marcxmlr:::.prototype_c4_native_read_offsets(
    source_file, offsets, batch_records = 2L, batch_bytes = 25000L)
  all <- marcxmlr::read_marcxml(source_file)
  ids <- unique(all$record_id[all$tag == "856"])
  expected <- all[all$record_id %in% ids, , drop = FALSE]
  expected$record_id <- match(expected$record_id, ids)
  rownames(expected) <- NULL
  expect_identical(got, expected)
  expect_identical(unique(got$record_id), seq_along(ids))

  none <- offsets[0, , drop = FALSE]
  expect_identical(marcxmlr:::.prototype_c4_native_read_offsets(source_file, none),
                   marcxmlr:::.empty_marcxml())

  prof <- marcxmlr:::.prototype_c4_native_read_offsets(
    source_file, offsets, batch_records = 2L, .profile = TRUE)
  expect_identical(prof$canonical, expected)
  expect_equal(prof$batches, 2L)
  expect_true(all(c("native_allocation_s", "native_init_s",
                    "native_cleanup_s") %in% names(prof$native_profile)))
  expect_true(all(c("r_visit_s", "r_call_s", "r_bind_s") %in%
                  names(prof$r_profile)))
  expect_true(all(is.finite(prof$native_profile)))
  expect_true(all(prof$native_profile >= 0))
})

test_that("C4 validates selected records but ignores discarded invalid MARC records", {
  skip_on_cran()
  # Byte ranges refer to complete XML records. An invalid discarded record
  # does not need to be processed by the native materialization engine.
  good <- '<record xmlns="http://www.loc.gov/MARC21/slim"><leader>00000nam a2200000 a 4500</leader></record>'
  bad <- '<record xmlns="http://www.loc.gov/MARC21/slim"><bogus/></record>'
  doc <- paste0('<collection xmlns="http://www.loc.gov/MARC21/slim">', bad, good,
                '</collection>')
  f <- tempfile(fileext = ".xml")
  on.exit(unlink(f), add = TRUE)
  writeBin(charToRaw(doc), f)
  pos <- regexpr(good, doc, fixed = TRUE)[[1L]] - 1L
  offsets <- data.frame(start_byte = pos,
                        end_byte = pos + nchar(good, type = "bytes"))
  actual <- marcxmlr:::.prototype_c4_native_read_offsets(f, offsets)
  expect_identical(unique(actual$record_id), 1L)
  expect_equal(nrow(actual), 1L)
  bad_pos <- regexpr(bad, doc, fixed = TRUE)[[1L]] - 1L
  bad_offsets <- data.frame(start_byte = bad_pos,
                            end_byte = bad_pos + nchar(bad, type = "bytes"))
  expect_error(marcxmlr:::.prototype_c4_native_read_offsets(f, bad_offsets),
               "valid MARCXML")
})

test_that("C4 offset batches can be written without full R materialization", {
  skip_on_cran()
  skip_if_not_installed("arrow")
  good <- '<record xmlns="http://www.loc.gov/MARC21/slim"><leader>00000nam a2200000 a 4500</leader></record>'
  f <- tempfile(fileext = ".xml")
  writeBin(charToRaw(paste0('<collection>', good, good, '</collection>')), f)
  on.exit(unlink(f), add = TRUE)
  prefix <- nchar('<collection>', type = 'bytes')
  size <- nchar(good, type = 'bytes')
  offsets <- data.frame(start_byte = c(prefix, prefix + size),
                        end_byte = c(prefix + size, prefix + 2 * size))
  out <- tempfile("c4-parquet-")
  on.exit(unlink(out, recursive = TRUE, force = TRUE), add = TRUE)
  info <- marcxmlr:::.prototype_c4_native_to_parquet_offsets(
    f, offsets, out, batch_records = 1L)
  expect_equal(info$records, 2)
  expect_equal(info$rows, 2)
  expect_equal(info$parquet_files, 2)
})
