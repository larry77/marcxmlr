test_that("C3 equals C1 for present and absent fields with compact IDs", {
  f <- system.file("extdata", "example-marcxml.xml", package = "marcxmlr")
  full <- read_marcxml(f)
  for (tag in c("001", "100", "650", "856", "999")) {
    predicate <- function(x, record_ids) record_ids %in% unique(x$record_id)
    c1 <- .prototype_read_marcxml_filtered(
      f, tag, predicate, screen_batch_records = 1L
    )
    c3 <- .prototype_read_marcxml_light_filtered(
      f, tag, predicate, screen_batch_records = 1L,
      batch_records = 1L
    )
    if (nrow(c1)) {
      c1$record_id <- match(c1$record_id, unique(c1$record_id))
    }
    expect_identical(c3, c1)
  }
  expect_identical(read_marcxml(f), full) # no-filter path unchanged
})

test_that("C3 supports absence tests and consecutive IDs across batches", {
  f <- system.file("extdata", "example-marcxml.xml", package = "marcxmlr")
  predicate <- function(x, record_ids) !(record_ids %in% unique(x$record_id))
  c1 <- .prototype_read_marcxml_filtered(f, "650", predicate,
                                         screen_batch_records = 1L)
  c3 <- .prototype_read_marcxml_light_filtered(f, "650", predicate,
                                               screen_batch_records = 1L)
  if (nrow(c1)) c1$record_id <- match(c1$record_id, unique(c1$record_id))
  expect_identical(c3, c1)
  expect_identical(
    .prototype_read_marcxml_light_filtered(f, "650", predicate, n_max = 0),
    .empty_marcxml()
  )
})

test_that("C3 validates selected records but not discarded MARC structures", {
  bad <- paste0(
    '<record><leader>00000nam a2200000 a 4500</leader>',
    '<datafield tag="999" ind1="0">', # invalid: missing ind2
    '<subfield code="a">bad</subfield></datafield></record>'
  )
  good <- paste0(
    '<record><leader>00000nam a2200000 a 4500</leader>',
    '<controlfield tag="001">selected</controlfield>',
    '<datafield tag="650" ind1=" " ind2="0">',
    '<subfield code="a">Metadata</subfield></datafield></record>'
  )
  f <- tempfile(fileext = ".xml")
  fg <- tempfile(fileext = ".xml")
  on.exit(unlink(c(f, fg)), add = TRUE)
  writeLines(paste0('<collection>', bad, good, '</collection>'), f)
  writeLines(paste0('<collection>', good, '</collection>'), fg)
  has650 <- function(x, record_ids) record_ids %in% unique(x$record_id)
  expect_identical(
    .prototype_read_marcxml_light_filtered(f, "650", has650, screen_batch_records = 1L),
    read_marcxml(fg)
  )
  expect_error(
    .prototype_read_marcxml_light_filtered(
      f, "999", function(x, ids) ids %in% unique(x$record_id)),
    "Selected MARCXML record failed native structural validation"
  )
  expect_error(
    .prototype_read_marcxml_filtered(f, "650", has650),
    "invalid MARCXML"
  )
})

test_that("C3 screening values reproduce C1 for subfield predicates", {
  f <- system.file("extdata", "gpo-cgp-part00-sample.xml", package = "marcxmlr")
  skip_if(!file.exists(f))
  predicate <- function(x, record_ids) {
    record_ids %in% unique(x$record_id[x$subfield_code == "a" &
                                             !is.na(x$value) & x$value == "Flood insurance"])
  }
  c1 <- .prototype_read_marcxml_filtered(f, "650", predicate,
                                         screen_batch_records = 23L)
  c3 <- .prototype_read_marcxml_light_filtered(f, "650", predicate,
                                               screen_batch_records = 23L)
  if (nrow(c1)) c1$record_id <- match(c1$record_id, unique(c1$record_id))
  expect_identical(c3, c1)
})
