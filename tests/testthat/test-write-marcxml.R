test_that("write_marcxml round trips the installed example exactly", {
  input <- system.file("extdata", "example-marcxml.xml", package = "marcxmlr")
  x <- read_marcxml(input)
  out <- tempfile(fileext = ".xml")

  expect_no_warning(write_marcxml(x, out))
  y <- read_marcxml(out)

  expect_identical(y, x)
})

test_that("write_marcxml escapes XML metacharacters and preserves Unicode", {
  x <- canonical_writer_fixture()
  out <- tempfile(fileext = ".xml")

  write_marcxml(x, out)
  y <- read_marcxml(out)

  expect_identical(y, x)
  text <- paste(readLines(out, warn = FALSE, encoding = "UTF-8"), collapse = "\n")
  expect_true(grepl("&amp;", text, fixed = TRUE))
  expect_true(grepl("&lt;", text, fixed = TRUE))
  expect_true(grepl("Žluťoučký kůň", text, fixed = TRUE))

  schema <- xml2::read_xml(testthat::test_path("fixtures", "writer-structural.xsd"))
  expect_true(xml2::xml_validate(xml2::read_xml(out), schema))
})

test_that("record subsetting preserves semantics and regenerates record_id", {
  x <- canonical_writer_fixture()
  selected <- x[x$record_id == 2L, ]
  out <- tempfile(fileext = ".xml")

  expect_warning(
    write_marcxml(selected, out),
    class = "marcxmlr_canonical_warning"
  )
  y <- read_marcxml(out)

  expect_identical(unique(y$record_id), 1L)
  expect_equal(canonical_semantics(y), canonical_semantics(selected))
})

test_that("complete field deletion preserves remaining MARC semantics", {
  x <- canonical_writer_fixture()
  edited <- x[!(x$record_id == 1L & x$field_order == 3L), ]
  out <- tempfile(fileext = ".xml")

  expect_warning(
    write_marcxml(edited, out),
    class = "marcxmlr_canonical_warning"
  )
  y <- read_marcxml(out)

  expect_equal(canonical_semantics(y), canonical_semantics(edited))
})

test_that("individual subfield deletion preserves remaining MARC semantics", {
  x <- canonical_writer_fixture()
  idx <- which(
    x$record_id == 1L &
      x$field_order == 4L &
      x$subfield_code == "a"
  )
  edited <- x[-idx[[1L]], ]
  out <- tempfile(fileext = ".xml")

  expect_warning(
    write_marcxml(edited, out),
    class = "marcxmlr_canonical_warning"
  )
  y <- read_marcxml(out)

  expect_equal(canonical_semantics(y), canonical_semantics(edited))
})

test_that("check FALSE suppresses coordinate warnings but not structural errors", {
  x <- canonical_writer_fixture()
  edited <- x[x$record_id == 2L, ]
  out <- tempfile(fileext = ".xml")

  expect_no_warning(write_marcxml(edited, out, check = FALSE))

  broken <- canonical_writer_fixture()
  idx <- which(broken$record_id == 1L & broken$field_order == 2L)
  broken$ind1[idx[[2L]]] <- "2"

  expect_error(
    write_marcxml(broken, tempfile(fileext = ".xml"), check = FALSE),
    class = "marcxmlr_canonical_error"
  )
})

test_that("pretty FALSE still produces readable MARCXML", {
  x <- canonical_writer_fixture()
  out <- tempfile(fileext = ".xml")

  write_marcxml(x, out, pretty = FALSE)

  expect_identical(read_marcxml(out), x)
})

test_that("records_per_file writes deterministic valid collection shards", {
  x <- canonical_writer_fixture()
  third <- x[x$record_id == 2L, ]
  third$record_id <- 3L
  x <- rbind(x, third)

  dir <- tempfile("marcxmlr-shards-")
  dir.create(dir)
  file <- file.path(dir, "catalogue.xml")

  paths <- write_marcxml(x, file, records_per_file = 2L)

  expect_identical(
    basename(paths),
    c("catalogue-00001.xml", "catalogue-00002.xml")
  )
  expect_true(all(file.exists(paths)))

  first <- read_marcxml(paths[[1L]])
  second <- read_marcxml(paths[[2L]])
  expect_identical(length(unique(first$record_id)), 2L)
  expect_identical(length(unique(second$record_id)), 1L)

  for (path in paths) {
    doc <- xml2::read_xml(path)
    expect_identical(xml2::xml_name(xml2::xml_root(doc)), "collection")
    expect_true(
      "http://www.loc.gov/MARC21/slim" %in% unname(xml2::xml_ns(doc))
    )
  }
})

test_that("finite splitting uses a numbered name even for one shard", {
  x <- canonical_writer_fixture()
  x <- x[x$record_id == 1L, ]

  dir <- tempfile("marcxmlr-one-shard-")
  dir.create(dir)
  file <- file.path(dir, "catalogue.xml")

  path <- write_marcxml(x, file, records_per_file = 50000L)

  expect_identical(basename(path), "catalogue-00001.xml")
  expect_true(file.exists(path))
})

test_that("empty canonical input writes an empty collection", {
  x <- canonical_writer_fixture()[0, ]
  out <- tempfile(fileext = ".xml")

  write_marcxml(x, out)
  doc <- xml2::read_xml(out)

  expect_identical(xml2::xml_name(xml2::xml_root(doc)), "collection")
  expect_length(xml2::xml_find_all(doc, "//*[local-name()='record']"), 0L)
})

test_that("records_per_file must be a positive whole number or Inf", {
  x <- canonical_writer_fixture()

  expect_error(
    write_marcxml(x, tempfile(fileext = ".xml"), records_per_file = 0L),
    class = "marcxmlr_argument_error"
  )
  expect_error(
    write_marcxml(x, tempfile(fileext = ".xml"), records_per_file = 1.5),
    class = "marcxmlr_argument_error"
  )
})


test_that("write_marcxml does not overwrite existing output", {
  x <- canonical_writer_fixture()
  out <- tempfile(fileext = ".xml")
  writeLines("sentinel", out)

  expect_error(
    write_marcxml(x, out),
    class = "marcxmlr_output_exists"
  )
  expect_identical(readLines(out, warn = FALSE), "sentinel")
})

test_that("write_marcxml preflights all shard targets before writing", {
  x <- canonical_writer_fixture()
  third <- x[x$record_id == 2L, ]
  third$record_id <- 3L
  x <- rbind(x, third)

  dir <- tempfile("marcxmlr-existing-shard-")
  dir.create(dir)
  requested <- file.path(dir, "catalogue.xml")
  existing <- file.path(dir, "catalogue-00002.xml")
  writeLines("sentinel", existing)

  expect_error(
    write_marcxml(x, requested, records_per_file = 2L),
    class = "marcxmlr_output_exists"
  )
  expect_false(file.exists(file.path(dir, "catalogue-00001.xml")))
  expect_identical(readLines(existing, warn = FALSE), "sentinel")
})


test_that("physical tibble row order does not define MARC order", {
  expected <- canonical_writer_fixture()
  shuffled <- expected[rev(seq_len(nrow(expected))), ]
  out <- tempfile(fileext = ".xml")

  expect_no_warning(write_marcxml(shuffled, out))
  observed <- read_marcxml(out)

  expect_identical(observed, expected)
})

test_that("edited field_order controls serialized field order", {
  x <- canonical_writer_fixture()
  edited <- x

  edited$field_order[x$record_id == 1L & x$field_order == 3L] <- 4L
  edited$field_order[x$record_id == 1L & x$field_order == 4L] <- 3L

  out <- tempfile(fileext = ".xml")
  expect_warning(
    write_marcxml(edited, out),
    class = "marcxmlr_canonical_warning"
  )
  observed <- read_marcxml(out)

  expect_equal(canonical_semantics(observed), canonical_semantics(edited))
})

test_that("edited subfield_order controls serialized subfield order", {
  x <- canonical_writer_fixture()
  edited <- x
  idx <- which(edited$record_id == 1L & edited$field_order == 2L)
  edited$subfield_order[idx] <- rev(edited$subfield_order[idx])

  out <- tempfile(fileext = ".xml")
  expect_no_warning(write_marcxml(edited, out))
  observed <- read_marcxml(out)

  expect_equal(canonical_semantics(observed), canonical_semantics(edited))
})

test_that("meaningful leading and trailing whitespace survives round trip", {
  x <- canonical_writer_fixture()
  idx <- which(x$record_id == 1L & x$field_order == 2L & x$subfield_code == "a")
  x$value[[idx[[1L]]]] <- "  title with surrounding whitespace  "
  out <- tempfile(fileext = ".xml")

  write_marcxml(x, out)
  observed <- read_marcxml(out)

  expect_identical(observed, x)
})

test_that("writer rejects MARCXML-invalid controlfield/datafield ordering", {
  x <- canonical_writer_fixture()
  x$field_order[x$record_id == 1L & x$field_order == 1L] <- 2L
  x$field_order[x$record_id == 1L & x$tag == "245"] <- 1L

  expect_error(
    write_marcxml(x, tempfile(fileext = ".xml")),
    class = "marcxmlr_canonical_error"
  )
})


test_that("writer rejects XML 1.0 forbidden characters before creating output", {
  x <- canonical_writer_fixture()
  idx <- which(x$record_id == 1L & x$field_order == 2L)[[1L]]
  x$value[[idx]] <- paste0("before", intToUtf8(1L), "after")
  out <- tempfile(fileext = ".xml")

  expect_error(
    write_marcxml(x, out),
    class = "marcxmlr_canonical_error"
  )
  expect_false(file.exists(out))
})

test_that("staged shard writing removes partial output after a later failure", {
  x <- canonical_writer_fixture()
  third <- x[x$record_id == 2L, ]
  third$record_id <- 3L
  x <- rbind(x, third)

  chunks <- .writer_split_record_ids(sort(unique(x$record_id)), 2L)
  dir <- tempfile("marcxmlr-staged-failure-")
  dir.create(dir)
  paths <- .writer_shard_paths(file.path(dir, "catalogue.xml"), length(chunks))

  calls <- 0L
  failing_writer <- function(x, record_ids, file, pretty) {
    calls <<- calls + 1L
    if (calls == 2L) {
      stop("simulated later shard failure", call. = FALSE)
    }
    writeLines("staged", file)
    invisible(file)
  }

  expect_error(
    .writer_write_outputs_staged(
      x,
      chunks = chunks,
      paths = paths,
      pretty = TRUE,
      write_collection = failing_writer
    ),
    "simulated later shard failure"
  )

  expect_false(any(file.exists(paths)))
  leftovers <- setdiff(list.files(dir, all.files = TRUE), c(".", ".."))
  expect_length(leftovers, 0L)
})

test_that("successful staged shard writing leaves only final outputs", {
  x <- canonical_writer_fixture()
  third <- x[x$record_id == 2L, ]
  third$record_id <- 3L
  x <- rbind(x, third)

  dir <- tempfile("marcxmlr-staged-success-")
  dir.create(dir)
  paths <- write_marcxml(
    x,
    file.path(dir, "catalogue.xml"),
    records_per_file = 2L
  )

  expect_true(all(file.exists(paths)))
  leftovers <- setdiff(list.files(dir, all.files = TRUE), c(".", ".."))
  expect_setequal(leftovers, basename(paths))
})
