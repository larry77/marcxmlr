# Experimental C1-F keeps strict record validation but fuses that traversal
# with extraction of the requested screening fields. C1 remains unchanged.

test_that("fused screening matches C1 across batch boundaries and predicates", {
  file <- system.file("extdata", "example-marcxml.xml", package = "marcxmlr")
  matching <- function(x, ids) ids %in% unique(x$record_id)
  missing <- function(x, ids) !(ids %in% unique(x$record_id))
  always <- function(x, ids) rep(TRUE, length(ids))
  never <- function(x, ids) rep(FALSE, length(ids))

  for (tag in c("001", "650", "LDR")) {
    for (pred in list(matching, missing, always, never)) {
      for (batch_size in c(1L, 2L)) {
        a <- .prototype_read_marcxml_filtered(file, tag, pred,
          screen_batch_records = batch_size)
        b <- .prototype_read_marcxml_filtered(file, tag, pred,
          screen_batch_records = batch_size, .fused = TRUE)
        expect_identical(b, a)
      }
    }
  }
})

test_that("fused screening returns the exact same selected GPO records", {
  file <- system.file("extdata", "gpo-cgp-part00-sample.xml", package = "marcxmlr")
  skip_if(!nzchar(file))
  pred <- function(x, ids) {
    matching <- x$record_id[x$tag == "650" & x$subfield_code == "a" &
                              x$value == "Flood insurance"]
    ids %in% matching
  }
  c1 <- .prototype_read_marcxml_filtered(file, "650", pred,
    screen_batch_records = 23L)
  fused <- .prototype_read_marcxml_filtered(file, "650", pred,
    screen_batch_records = 23L, .fused = TRUE)
  expect_identical(fused, c1)
  expect_identical(length(unique(fused$record_id)), 28L)
  expect_identical(nrow(fused), 1320L)
})

test_that("fused screening preserves n_max behavior", {
  file <- system.file("extdata", "example-marcxml.xml", package = "marcxmlr")
  pred <- function(x, ids) rep(TRUE, length(ids))
  for (n in c(0L, 1L, 2L)) {
    expect_identical(
      .prototype_read_marcxml_filtered(file, "650", pred, n_max = n,
        .fused = TRUE),
      .prototype_read_marcxml_filtered(file, "650", pred, n_max = n)
    )
  }
})

test_that("fused screening rejects malformed non-selected fields", {
  # The requested field is 650; the malformed field is 999 and therefore
  # deliberately outside the screening projection. Neither path may ignore it.
  bad <- tempfile(fileext = ".xml")
  on.exit(unlink(bad), add = TRUE)
  writeLines(c(
    '<collection xmlns="http://www.loc.gov/MARC21/slim">',
    '<record><leader>01234nam a2200000 a 4500</leader>',
    '<datafield tag="650" ind1=" " ind2="0"><subfield code="a">Test</subfield></datafield>',
    '<datafield tag="999" ind1=" " ind2="0"></datafield>',
    '</record></collection>'
  ), bad, useBytes = TRUE)
  pred <- function(x, ids) rep(FALSE, length(ids))
  expect_error(.prototype_read_marcxml_filtered(bad, "650", pred),
    "Unsupported or invalid")
  expect_error(.prototype_read_marcxml_filtered(bad, "650", pred,
    .fused = TRUE), "Unsupported or invalid")
})
