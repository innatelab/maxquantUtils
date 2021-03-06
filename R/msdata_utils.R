# utilities for preparing msdata list

uniprot_fasta_extract_ac <- function(fasta_headers) {
    str_replace_all(fasta_headers, "(^|;)(?:sp|tr)\\|([a-zA-Z0-9_-]+)\\|\\S+?(?=$|;)", "\\1\\2")
}

agg_protgroup_col <- function(data) {
  if (is.character(data)) {
    str_c(unique(data), collapse=';')
  } else if (is.logical(data)) {
    any(data) # FIXME what if all?
  } else {
    error("don't know how to aggregate ", typeof(data), " type")
  }
}

#' @export
append_protgroups_info <- function(msdata, msdata_wide, proteins_info = NULL,
                                   fix_protein_info = TRUE,
                                   import_columns = NULL, verbose = TRUE) {
    if (verbose) message("Preparing msdata$protgroups data frame...")
    msdata_colgroups <- attr(msdata_wide, "column_groups")
    pg_df <- dplyr::select(msdata_wide, !!msdata_colgroups$protgroup) %>%
        dplyr::distinct() %>% dplyr::arrange(protgroup_id)
    # keep only protgroups with data
    intensity_dfnames <- str_subset(names(msdata), "intensities$")
    for (dfname in intensity_dfnames) {
        if (rlang::has_name(msdata[[dfname]], "protgroup_id")) {
            if (verbose) message("Contstraining msdata$protgroups to protgroups found in ", dfname)
            pg_df <- dplyr::semi_join(pg_df, msdata[[dfname]])
        }
    }
    if (verbose) message(nrow(pg_df), " protgroup(s) found")
    if (fix_protein_info) {
        pg_df <- pg_df %>%
            dplyr::mutate(# fix ACs due to incorrect mqpar parse rules
                          protein_acs = uniprot_fasta_extract_ac(protein_acs),
                          majority_protein_acs = uniprot_fasta_extract_ac(majority_protein_acs))
    }
    maybe_expand_collapsed_metric <- function(df, collapsed_col, separated_col=collapsed_col) {
        if (!(collapsed_col %in% colnames(df))) return (tibble())
        tmp_col <- str_c(separated_col, "_tmp")
        res <- expand_collapsed(df, collapsed_col=collapsed_col, separated_col=tmp_col)
        res[[separated_col]] = parse_integer(res[[tmp_col]])
        res[[tmp_col]] <- NULL
        return (res)
    }
    protein2pg_dfs <- list(
      expand_collapsed(pg_df, collapsed_col="protein_acs", separated_col = "protein_ac", extra_cols = "protgroup_id") %>%
        dplyr::select(-protein_acs),
      maybe_expand_collapsed_metric(pg_df, collapsed_col="npeptides"),
      maybe_expand_collapsed_metric(pg_df, collapsed_col="npeptides_unique"),
      maybe_expand_collapsed_metric(pg_df, collapsed_col="npeptides_unique_razor")
    )
    protein2pg_df <- bind_cols(protein2pg_dfs[sapply(protein2pg_dfs, nrow) > 0]) %>%
        dplyr::left_join(expand_protgroup_acs(pg_df, acs_col="majority_protein_acs", ac_col = "protein_ac") %>%
                         dplyr::mutate(is_majority = TRUE)) %>%
        dplyr::mutate(is_majority=replace_na(is_majority, FALSE)) %>%
        dplyr::ungroup() %>%
        dplyr::select(-row_ix, -prot_ix)
    if ("npeptides_unique_razor" %in% colnames(protein2pg_df) &&
        "npeptides_unique" %in% colnames(protein2pg_df)) {
        protein2pg_df <- dplyr::mutate(protein2pg_df, npeptides_razor = npeptides_unique_razor - npeptides_unique)
    }

    if (!is.null(proteins_info)) {
        proteins_df <- semi_join(proteins_info, protein2pg_df) %>%
            dplyr::left_join(dplyr::select(dplyr::filter(protein2pg_df, is_majority),
                                           protein_ac, protgroup_id))
        if (fix_protein_info) {
            # fix gene and protein names using FASTA information
            fix_cols <- c("protein_names" = "protein_name", "gene_names" = "gene_name")
        } else {
            fix_cols <- c()
        }
        agg_cols <- fix_cols
        if (!is.null(import_columns)) {
            agg_cols <- c(agg_cols, import_columns)
        }
        fixpg_df <- dplyr::left_join(dplyr::select(pg_df, protgroup_id),
                                     dplyr::group_by(proteins_df, protgroup_id) %>%
                                     dplyr::summarise_at(agg_cols, agg_protgroup_col) %>%
                                     dplyr::ungroup())
        if (any(fixpg_df$protgroup_id != pg_df$protgroup_id)) {
            warning("Incorrect fixed protgroups info, skipping")
        } else {
            for (fix_col in intersect(names(fix_cols), colnames(pg_df))) {
                pg_mask <- !is.na(fixpg_df[[fix_col]]) & is.na(pg_df[[fix_col]])
                if (any(pg_mask)) {
                    if (verbose) message("Fixing ", sum(pg_mask), " ", fix_col, " using provided proteins_info")
                    pg_df[pg_mask, fix_col] <- fixpg_df[pg_mask, fix_col]
                }
            }
            for (imp_col in import_columns) {
                if (verbose) message("Importing ", imp_col, " from proteins_info")
                pg_df[, imp_col] <- fixpg_df[[imp_col]]
            }
        }
    } else {
        proteins_df <- NULL
    }
    msdata$protgroups <- pg_df
    msdata$protein2protgroup <- protein2pg_df
    msdata$proteins <- proteins_df
    return (msdata)
}

#' @export
mschannel_statistics <- function(msdata, obj="protgroup") {
    objs_dfname <- str_c(obj, "s")
    obj_idcol = str_c(obj, "_id")
    if (!rlang::has_name(msdata, objs_dfname)) {
        stop("msdata contains no `", objs_dfname, " data")
    }
    objs_df = msdata[[objs_dfname]]
    objs_df$object_id = objs_df[[obj_idcol]]
    obj_tagintensities_dfname <- str_c(obj, "_tagintensities")
    if (!rlang::has_name(msdata, obj_tagintensities_dfname)) {
      stop("msdata contains no `", obj, "_tagintensities` data, msrun_statistics() should be used instead")
    }
    obj_tagintensities_df <- msdata[[obj_tagintensities_dfname]]
    obj_tagintensities_df$object_id <- obj_tagintensities_df[[obj_idcol]]
    res <- dplyr::left_join(tidyr::expand(dplyr::filter(obj_tagintensities_df, !is.na(object_id)),
                                          object_id, msrun, mstag),
                            dplyr::filter(obj_tagintensities_df, !is.na(object_id)) %>%
                            dplyr::select(object_id, msrun, mstag, intensity)) %>%
    dplyr::inner_join(dplyr::select(msdata$mschannels, msrun, mstag, mschannel) %>%
                      dplyr::distinct()) %>%
    #dplyr::group_by(protgroup_id, condition) %>% dplyr::filter(any(!is.na(intensity))) %>%
    dplyr::group_by(mschannel, mstag, msrun) %>%
    summarize(log2_intensity.mean = mean(log2(intensity[!is.na(intensity)])),
              log2_intensity.median = median(log2(intensity[!is.na(intensity)])),
              log2_intensity.sd = sd(log2(intensity[!is.na(intensity)])),
              n = n(),
              n_missing = sum(is.na(intensity))) %>%
    dplyr::ungroup()

    obj_idents_dfname <- str_c(obj, "_idents")
    if (rlang::has_name(msdata, obj_idents_dfname)) {
      obj_idents_df <- msdata[[obj_idents_dfname]]
      obj_idents_df$object_id <- obj_idents_df[[obj_idcol]]
    } else {
      obj_idents_df <- obj_tagintensities_df
    }
    if (!is.null(obj_idents_df)) {
      ident_stats <- dplyr::left_join(dplyr::filter(obj_idents_df, !is.na(object_id)),
                                      dplyr::select(msdata$mschannels, msrun, any_of("msrun_mq")) %>% dplyr::distinct()) %>%
        dplyr::mutate(is_matching = ident_type %in% c("By matching", "MULTI-MATCH", "MULTI-MATCH-MSMS"),
                      is_msms = ident_type %in% c("By MS/MS", "MULTI-MSMS", "ISO-MSMS", "MSMS", "MULTI-SECPEP")) %>%
        dplyr::group_by(msrun) %>%
        summarize(n_matching = n_distinct(object_id[is_matching], na.rm = TRUE),
                  n_msms = n_distinct(object_id[is_msms], na.rm = TRUE)) %>%
        dplyr::ungroup()
      res <- left_join(res, ident_stats)
    } else {
      warning("No protgroup ident_type data found")
    }
    return (res)
}

#' @export
msrun_statistics <- function(msdata, obj="protgroup") {
  objs_dfname <- str_c(obj, "s")
  obj_idcol = str_c(obj, "_id")
  if (!rlang::has_name(msdata, objs_dfname)) {
    stop("msdata contains no `", objs_dfname, " data")
  }
  objs_df = msdata[[objs_dfname]]
  objs_df$object_id = objs_df[[obj_idcol]]
  if (rlang::has_name(msdata, str_c(obj, "_tagintensities"))) {
    warning("msdata contains `", obj, "_tagintensities` data, mschannel_statistics() should be used instead")
  }
  obj_intensities_dfname <- str_c(obj, "_intensities")
  if (!rlang::has_name(msdata, obj_intensities_dfname)) {
    warning("msdata contains no `", obj_intensities_dfname, "` data")
  }
  obj_intensities_df = msdata[[obj_intensities_dfname]]
  obj_intensities_df$object_id = obj_intensities_df[[obj_idcol]]
  res <- dplyr::left_join(tidyr::expand(dplyr::filter(obj_intensities_df, !is.na(object_id)),
                                        object_id, msrun),
                          dplyr::filter(obj_intensities_df, !is.na(object_id)) %>%
                          dplyr::select(object_id, msrun, intensity)) %>%
    dplyr::inner_join(dplyr::select(msdata$msruns, msrun) %>% dplyr::distinct()) %>%
    #dplyr::group_by(protgroup_id, condition) %>% dplyr::filter(any(!is.na(intensity))) %>%
    dplyr::group_by(msrun) %>%
    summarize(log2_intensity.mean = mean(log2(intensity[!is.na(intensity)])),
              log2_intensity.median = median(log2(intensity[!is.na(intensity)])),
              log2_intensity.sd = sd(log2(intensity[!is.na(intensity)])),
              n = n(),
              n_missing = sum(is.na(intensity))) %>%
    dplyr::ungroup()

  obj_idents_dfname <- str_c(obj, "_idents")
  if (rlang::has_name(msdata, obj_idents_dfname)) {
    obj_idents_df <- msdata[[obj_idents_dfname]]
    obj_idents_df$object_id = obj_idents_df[[obj_idcol]]
  } else {
    obj_idents_df <- obj_intensities_df
  }
  if (!is.null(obj_idents_df)) {
    ident_stats <- dplyr::left_join(dplyr::filter(obj_idents_df, !is.na(object_id)),
                                    dplyr::select(msdata$msruns, msrun, any_of("msrun_mq")) %>% dplyr::distinct()) %>%
      dplyr::mutate(is_matching = ident_type %in% c("By matching", "MULTI-MATCH", "MULTI-MATCH-MSMS"),
                    is_msms = ident_type %in% c("By MS/MS", "MULTI-MSMS", "ISO-MSMS", "MSMS", "MULTI-SECPEP")) %>%
      dplyr::group_by(msrun) %>%
      summarize(n_matching = n_distinct(object_id[is_matching], na.rm = TRUE),
                n_msms = n_distinct(object_id[is_msms], na.rm = TRUE)) %>%
      dplyr::ungroup()
    res <- left_join(res, ident_stats)
  } else {
    warning("No protgroup ident_type data found")
  }
  return (res)
}

#' @export
# FIXME more checks/control over the columns of intensities_df/stats_df
impute_intensities <- function(intensities_df, stats_df, log2_mean_offset=-1.8, log2_sd_scale=0.3){
    res <- dplyr::inner_join(intensities_df, stats_df) %>%
        dplyr::mutate(intensity_imputed = if_else(is.na(intensity),
                                                  2^(rnorm(n(), mean=log2_intensity.mean + log2_intensity.sd * log2_mean_offset,
                                                                sd=log2_intensity.sd * log2_sd_scale)),
                                                  intensity)) %>%
        dplyr::ungroup()
    # don't take stats_df columns along
    dplyr::select(res, one_of(colnames(intensities_df)), intensity_imputed)
}

#' @export
cluster_msprofiles <- function(msdata, msrun_stats, obj_col="pepmodstate_id", msrun_col="msrun", nclu=4) {
  # create matrix of intensities
  intensities.df <- tidyr::expand(msdata, !!!rlang::syms(c(obj_col, msrun_col))) %>%
    dplyr::left_join(dplyr::select(msdata, any_of(c(obj_col, msrun_col, "intensity"))),
                     by=c(obj_col, msrun_col)) %>%
    impute_intensities(msrun_stats) %>%
    dplyr::arrange_at(c(obj_col, msrun_col))
  # handle trivial cases
  if (n_distinct(intensities.df[[obj_col]]) == 1L ||
      n_distinct(intensities.df[[msrun_col]]) == 1L) {
    return(tibble(!!obj_col := unique(intensities.df[[obj_col]]),
            profile_cluster = 1L,
            nsimilar_profiles = 1L))
  }
  obj_stats.df <- group_by(intensities.df, !!!rlang::syms(obj_col)) %>%
    summarise(n_quants = sum(!is.na(intensity))) %>%
    dplyr::ungroup()
  # add a bit of noise to avoid zero variance
  intensities.mtx <- matrix(log2(pmax(intensities.df$intensity_imputed + rnorm(nrow(intensities.df)), 0)),
                            ncol = n_distinct(intensities.df[[obj_col]]),
                            dimnames = list(msrun = unique(intensities.df[[msrun_col]]),
                                            object = unique(intensities.df[[obj_col]])))
  obj.pca <- stats::prcomp(intensities.mtx, scale.=TRUE)
  # create object feature matrix
  obj.pca_featmtx <- obj.pca$rotation * crossprod(t(rep.int(1, nrow(obj.pca$rotation))),
                                                  summary(obj.pca)$importance[2,])
  
  res <- tibble(!!obj_col := parse_integer(rownames(obj.pca_featmtx)),
         tmp_profile_cluster = stats::cutree(hclust(dist(obj.pca_featmtx), method="single"),
                                         min(c(nclu, nrow(obj.pca_featmtx), ncol(obj.pca_featmtx)))))
  # assign profile_cluster indices from largest to smallest clusters
  res_clustats <- dplyr::inner_join(res, obj_stats.df) %>%
    dplyr::group_by(tmp_profile_cluster) %>%
    dplyr::summarise(nsimilar_profiles = n(),
                     n_quants = sum(n_quants, na.rm=TRUE),
                     n_quants_median = median(n_quants, na.rm=TRUE)) %>%
    dplyr::ungroup() %>%
    dplyr::arrange(desc(n_quants), desc(nsimilar_profiles)) %>%
    dplyr::mutate(profile_cluster = row_number())

  return(inner_join(res, res_clustats) %>%
    dplyr::select(-tmp_profile_cluster))
}
