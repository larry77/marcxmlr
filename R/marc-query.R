# Record-level MARC query objects and tibble/Arrow evaluation.

.marc_query <- function(...) {
  structure(list(...), class = "marc_query")
}

.marc_string <- function(x, name, allow_null = TRUE) {
  if (is.null(x) && allow_null) return(invisible(NULL))
  if (!is.character(x) || length(x) != 1L || is.na(x) || !nzchar(x)) {
    stop(sprintf("`%s` must be a single non-empty character string%s.",
                 name, if (allow_null) " or NULL" else ""), call. = FALSE)
  }
  invisible(NULL)
}

#' Test whether a MARC record contains a matching field or subfield
#'
#' `marc_has()` constructs a query specification, not a row-wise predicate.
#' Conditions within one call apply to the same canonical row; `&`, `|`, and
#' `!` combine conditions at the **record** level. Use `marc_filter_records()`
#' on a canonical tibble or an Arrow Dataset, or pass the query as `filter`
#' to `read_marcxml()` or `marcxml_to_parquet()`.
#'
#' @param tag MARC field tag (or `"LDR"` for the leader).
#' @param subfield Optional subfield code.
#' @param equals Optional case-sensitive exact value.
#' @param contains Optional case-sensitive literal substring; cannot be used
#'   together with `equals`.
#' @param ind1,ind2 Optional indicators (a single blank is allowed).
#' @return An object of class `marc_query` that supports `&`, `|`, and `!`.
#' @examples
#' q <- marc_has("650", subfield = "a", contains = "Economics") &
#'   !marc_has("999")
#' @export
marc_has <- function(tag, subfield = NULL, equals = NULL, contains = NULL,
                     ind1 = NULL, ind2 = NULL) {
  .marc_string(tag, "tag", allow_null = FALSE)
  for (arg in c("subfield", "equals", "contains", "ind1", "ind2")) {
    .marc_string(get(arg, inherits = FALSE), arg)
  }
  if (!is.null(equals) && !is.null(contains)) {
    stop("Specify only one of `equals` and `contains`.", call. = FALSE)
  }
  .marc_query(op = "has", tag = tag, subfield = subfield,
              equals = equals, contains = contains, ind1 = ind1, ind2 = ind2)
}

#' @rdname marc_has
#' @param e1,e2 MARC query objects; `e2` is unused for unary `!`.
#' @export
Ops.marc_query <- function(e1, e2) {
  op <- .Generic
  if (op == "!") {
    if (!inherits(e1, "marc_query")) {
      stop("`!` requires a MARC query.", call. = FALSE)
    }
    return(.marc_query(op = "not", child = e1))
  }
  if (!(op %in% c("&", "|"))) {
    stop("MARC queries support only `&`, `|` and `!`.", call. = FALSE)
  }
  if (!inherits(e1, "marc_query") || !inherits(e2, "marc_query")) {
    stop("Both operands must be MARC queries (created by `marc_has()`).",
         call. = FALSE)
  }
  .marc_query(op = if (op == "&") "and" else "or", left = e1, right = e2)
}

# Internal: build a lazy relation containing selected record IDs.
.marc_matching_ids <- function(data, query, universe) {
  op <- query$op

  if (op == "has") {
    conditions <- list(rlang::expr(.data$tag == !!(query$tag)))
    if (!is.null(query$subfield)) {
      conditions <- c(conditions, list(
        rlang::expr(.data$subfield_code == !!(query$subfield))
      ))
    }
    if (!is.null(query$equals)) {
      conditions <- c(conditions, list(
        rlang::expr(.data$value == !!(query$equals))
      ))
    }
    if (!is.null(query$contains)) {
      conditions <- c(conditions, list(
        rlang::expr(grepl(!!(query$contains), .data$value, fixed = TRUE))
      ))
    }
    if (!is.null(query$ind1)) {
      conditions <- c(conditions, list(
        rlang::expr(.data$ind1 == !!(query$ind1))
      ))
    }
    if (!is.null(query$ind2)) {
      conditions <- c(conditions, list(
        rlang::expr(.data$ind2 == !!(query$ind2))
      ))
    }
    return(data |>
             dplyr::filter(!!!conditions) |>
             dplyr::select("record_id") |>
             dplyr::distinct())
  }

  if (op == "and") {
    left <- .marc_matching_ids(data, query$left, universe)
    right <- .marc_matching_ids(data, query$right, universe)
    return(dplyr::semi_join(left, right, by = "record_id"))
  }
  if (op == "or") {
    left <- .marc_matching_ids(data, query$left, universe)
    right <- .marc_matching_ids(data, query$right, universe)
    return(dplyr::distinct(dplyr::union_all(left, right)))
  }
  if (op == "not") {
    positive <- .marc_matching_ids(data, query$child, universe)
    return(dplyr::anti_join(universe, positive, by = "record_id"))
  }
  stop("Invalid MARC query object.", call. = FALSE)
}

#' Filter complete canonical MARC records
#'
#' Apply a `marc_has()` query to an already materialized canonical tibble or
#' to an Arrow Dataset. Selection is by `record_id`, and **all rows** belonging
#' to selected records are returned. Arrow operations remain lazy until
#' `dplyr::collect()` is called. `record_id` must uniquely identify records
#' across the entire input Dataset (including all Parquet fragments).
#'
#' @param .data A canonical MARC tibble or Arrow Dataset.
#' @param query A `marc_has()` query, possibly combined using `&`, `|`, `!`.
#' @return All canonical rows of records matching `query`, as a tibble or
#'   lazy Arrow query depending on `.data`.
#' @examples
#' x <- tibble::tibble(record_id = c(1L, 2L), tag = c("650", "856"),
#'   subfield_code = c("a", "u"), value = c("Economics", "example.org"),
#'   ind1 = c(" ", "4"), ind2 = c("0", "0"))
#' marc_filter_records(x, marc_has("650"))
#' @importFrom rlang .data
#' @export
marc_filter_records <- function(.data, query) {
  if (!requireNamespace("dplyr", quietly = TRUE) ||
      !requireNamespace("rlang", quietly = TRUE)) {
    stop("Install `dplyr` and `rlang` to use MARC queries.", call. = FALSE)
  }
  if (!inherits(query, "marc_query")) {
    stop("`query` must be built with `marc_has()` and optional `&`, `|`, `!`.",
         call. = FALSE)
  }
  required <- c("record_id", "tag", "subfield_code", "value", "ind1", "ind2")
  absent <- setdiff(required, names(.data))
  if (length(absent)) {
    stop("Missing canonical columns: ", paste(absent, collapse = ", "),
         call. = FALSE)
  }
  # Caller-supplied grouping must not affect filtering or the ID universe.
  data <- dplyr::ungroup(.data)
  universe <- data |>
    dplyr::select("record_id") |>
    dplyr::distinct()
  ids <- .marc_matching_ids(data, query, universe)
  dplyr::semi_join(data, ids, by = "record_id")
}
