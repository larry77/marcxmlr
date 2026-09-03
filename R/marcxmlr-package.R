#' marcxmlr: Faithful and scalable MARCXML parsing
#'
#' Parse MARC 21 XML into a canonical tidy long representation while
#' preserving repeated structures and source order. Use [read_marcxml()] for
#' in-memory work and [marcxml_to_parquet()] for bounded-memory conversion to a
#' disk-backed Parquet dataset.
#'
#' @seealso
#' * <https://www.loc.gov/standards/marcxml/>
#' * <https://www.loc.gov/marc/marcdocz.html>
#'
#' @importFrom stats ave
#' @keywords internal
"_PACKAGE"
