#' dmrff.meta
#'
#' Identify differentially methylated regions by meta-analysing multiple studies
#' using variance-weighted fixed effects meta-analysis.
#'
#' @param objects List of objects generated by \code{\link{dmrff.pre}}
#' for each participating EWAS.
#' @param p.cutoff Unadjusted p-value cutoff for membership in a candidate DMR
#' (Default: 0.05).
#' @param maxgap Maximum distance between consecutive features (Default: 500bp).
#' @param verbose If \code{TRUE} (default), then output status messages.
#' @return A data frame listing all candidate regions and their summary statistics.
#' 
#' @examples
#' pre1 <- dmrff.pre(est1, se1, p1, meth1, ...)
#' pre2 <- dmrff.pre(est2, se2, p2, meth2, ...)
#' ...
#' pre9 <- dmrff.pre(est9, se9, p9, meth9, ...)
#' meta <- dmrff.meta(list(pre1, pre2, ..., pre9))
#' meta$dmrs[which(meta$dmrs$p.adjust < 0.05), ]
#' 
#' @export
dmrff.meta <- function(objects, maxgap=500, p.cutoff=0.05, verbose=T) {
    stopifnot(is.list(objects))
    stopifnot(length(objects) > 1)

    ## sort object data by genomic position (rho is already sorted, see dmrff.pre)
    for (i in 1:length(objects)) {
        idx <- order(objects[[i]]$chr, objects[[i]]$pos)
        objects[[i]]$sites <- objects[[i]]$sites[idx]
        objects[[i]]$chr <- objects[[i]]$chr[idx]
        objects[[i]]$pos <- objects[[i]]$pos[idx]
        objects[[i]]$estimate <- as.numeric(objects[[i]]$estimate[idx])
        objects[[i]]$se <- as.numeric(objects[[i]]$se[idx])
    }
    
    ## identify a set of CpG sites in every dataset
    sites <- objects[[1]]$sites
    for (i in 2:length(objects))
        sites <- intersect(sites, objects[[i]]$sites)

    ## extract CpG site summary statistics
    estimate <- sapply(objects, function(obj)
                       obj$estimate[match(sites, obj$sites)])
    se <- sapply(objects, function(obj)
                 obj$se[match(sites, obj$sites)])

    ## meta-analysis CpG site associations
    ma <- ivwfe.ma(estimate, se)
    idx <- match(sites, objects[[1]]$sites)
    ma$chr <- objects[[1]]$chr[idx]
    ma$pos <- objects[[1]]$pos[idx]

    ## identify candidate regions
    candidates <- dmrff.candidates(ma$estimate, ma$p.value, ma$chr, ma$pos,
                                   maxgap=maxgap, p.cutoff=p.cutoff,
                                   verbose=verbose)

    ## shrink candidate regions and meta-analyze statistics
    compute.dmr.stats <- function(start.idx,end.idx) {
        stats <- sapply(1:length(objects), function(i) {
            start.idx <- which(objects[[i]]$sites == sites[start.idx])
            end.idx <- which(objects[[i]]$sites == sites[end.idx])
            idx <- start.idx:end.idx
            if (length(idx) > ncol(objects[[i]]$rho))
                return(c(B=0,S=1))
            ivwfe.stats(objects[[i]]$estimate[idx],
                        objects[[i]]$se[idx],
                        rho=extract.rho(objects[[i]]$rho[idx,,drop=F]))
        })
        ivwfe.ma(stats["B",,drop=F], stats["S",,drop=F])
    }
    compute.dmr.z <- function(start.idx,end.idx) {
        compute.dmr.stats(start.idx, end.idx)$z
    }
    stats <- shrink.candidates(candidates$start.idx,
                               candidates$end.idx,
                               compute.dmr.z)

    full <- do.call(rbind, mclapply(1:nrow(stats), function(i) {
        compute.dmr.stats(stats$start.idx[i], stats$end.idx[i])
    }))

    stats$B <- NA
    stats$S <- NA
    stats$estimate <- full[,"estimate"]
    stats$se <- full[,"se"]
    
    list(ewas=ma, 
         dmrs=collate.stats(stats, ma$chr, ma$pos))
}

#' dmrff.cohort
#'
#' Identify differentially methylated regions 
#' within an individual dataset with a `pre` object.
#'
#' @param object Object generated by \code{\link{dmrff.pre}} for the dataset.
#' @param p.cutoff Unadjusted p-value cutoff for membership in a candidate DMR
#' (Default: 0.05).
#' @param maxgap Maximum distance between consecutive features (Default: 500bp).
#' @param verbose If \code{TRUE} (default), then output status messages.
#' @return A data frame listing all candidate regions and their summary statistics.
#' 
#' @examples
#' pre <- dmrff.pre(est, se, p, meth, ...)
#' dmrs <- dmrff.cohort(pre)
#' dmrs[which(dmrs$p.adjust < 0.05), ]
#' 
#' @export
dmrff.cohort <- function(object, maxgap=500, p.cutoff=0.05, verbose=T) {
    idx <- order(object$chr, object$pos)
    object$sites <- object$sites[idx]
    object$chr <- object$chr[idx]
    object$pos <- object$pos[idx]
    object$estimate <- as.numeric(object$estimate[idx])
    object$se <- as.numeric(object$se[idx])
    object$p.value <- 2*pnorm(abs(object$estimate/object$se), lower.tail=F)

    candidates <- dmrff.candidates(estimate=object$estimate,
                                   p.value=object$p.value,
                                   chr=object$chr, 
                                   pos=object$pos,
                                   maxgap=maxgap,
                                   p.cutoff=p.cutoff,
                                   verbose=verbose)
 
    stats <- shrink.candidates(candidates$start.idx, candidates$end.idx,
                               function(start.idx,end.idx) {
                                   idx <- start.idx:end.idx
                                   if (length(idx) > ncol(object$rho)) return(0) 
                                   ivwfe.getz(object$estimate[idx], object$se[idx],
                                              rho=extract.rho(object$rho[idx,,drop=F]))
                               })

    full <- do.call(rbind, mclapply(1:nrow(stats), function(i) {
        idx <- stats$start.idx[i]:stats$end.idx[i]
        if (length(idx) > ncol(object$rho)) return(c(B=0,S=1)) 
        ivwfe.stats(object$estimate[idx], object$se[idx],
                    rho=extract.rho(object$rho[idx,,drop=F]))
    }))

    stats$estimate <- stats$B <- full[,"B"]
    stats$se <- stats$S <- full[,"S"]
    
    collate.stats(stats, object$chr, object$pos)
}

extract.rho <- function(pre) {
    n <- nrow(pre)
    rho <- diag(x=1.05, n)
    if (n > 1) 
        for (i in 1:(n-1)) {
            vals <- pre[i,1:(n-i)]
            rho[i,(i+1):n] <- vals
            rho[(i+1):n,i] <- vals
        }
    rho
}




