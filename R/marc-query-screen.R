# Experimental C4 query screening. This file does not alter the public
# read_marcxml() / marcxml_to_parquet() interface or legacy filter paths.
# It accepts the standalone marc_query objects from the prototype scripts.

.c4_compile_marc_query <- function(query) {
  predicates <- list()
  program <- integer()
  fields <- c("tag", "subfield", "equals", "contains", "ind1", "ind2")

  walk <- function(q) {
    if (!inherits(q, "marc_query") || !is.list(q) ||
        !is.character(q$op) || length(q$op) != 1L || is.na(q$op)) {
      stop("Invalid MARC query object.", call. = FALSE)
    }
    if (identical(q$op, "has")) {
      for (name in fields) {
        value <- q[[name]]
        if (!is.null(value) &&
            (!is.character(value) || length(value) != 1L ||
             is.na(value) || !nzchar(value))) {
          stop("Invalid MARC query predicate `", name, "`.", call. = FALSE)
        }
      }
      if (is.null(q$tag) ||
          (!is.null(q$equals) && !is.null(q$contains))) {
        stop("Invalid MARC query predicate.", call. = FALSE)
      }
      predicates[[length(predicates) + 1L]] <<- q[fields]
      program <<- c(program, as.integer(length(predicates)))
    } else if (identical(q$op, "not")) {
      walk(q$child)
      program <<- c(program, -3L)
    } else if (q$op %in% c("and", "or")) {
      walk(q$left)
      walk(q$right)
      program <<- c(program, if (q$op == "and") -1L else -2L)
    } else {
      stop("Invalid MARC query Boolean operator.", call. = FALSE)
    }
  }

  walk(query)
  columns <- stats::setNames(lapply(fields, function(field) {
    vapply(predicates, function(p) {
      value <- p[[field]]
      if (is.null(value)) NA_character_ else enc2utf8(value)
    }, character(1L), USE.NAMES = FALSE)
  }), fields)
  list(predicates = columns, program = program)
}

.c4_screen_query_file <- function(file, query) {
  .c4_check_encoding(file)
  spec <- .c4_compile_marc_query(query)
  cols <- .Call(
    C_marcxml_query_offset_index,
    normalizePath(file, winslash = "/", mustWork = TRUE),
    spec$predicates, spec$program
  )
  tibble::new_tibble(cols, nrow = length(cols[[1L]]))
}
