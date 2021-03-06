#!/usr/bin/Rsript
# ---------------------------------------------------------#
# Filename      : DGEA.R                                   #
# Authors       : IsmailM, Nazrath, Suresh, Marian, Anisa  #
# Description   : Gene Set Enrichment Analysis             #
# Rscript gage.R --accession GDS5093 --dbrdata ~/Desktop/GDS5093.RData --rundir ~/Desktop/ --factor "disease.state" --popA "Dengue Hemorrhagic Fever,Convalescent,Dengue Fever" --popB "healthy control"  --comparisontype ExpVsCtrl --genesettype KEGG --distance "euclidean" --clustering "average" --clusterby "Complete" --heatmaprows 100 --dendrow TRUE --dendcol TRUE --dev TRUE
# ---------------------------------------------------------#

#############################################################################
#                        Import Libraries                                   #
#############################################################################

# load required libraries and silence library loading messages on command line
suppressMessages(library("argparser"))     # Argument passing
suppressMessages(library("Cairo"))         # Plots saving
suppressMessages(library("DMwR"))          # Outlier Prediction for clustering
suppressMessages(library("gage"))          # Does the analysis
suppressMessages(library("gageData"))      # Lets data be used by gage
suppressMessages(library("GEOquery"))      # GEO dataset Retrieval
suppressMessages(library("GO.db"))         # Loads GO database
suppressMessages(library("jsonlite"))      # Convert R object to JSON format
suppressMessages(library("pathview"))      # Interaction networks & used to get ENTREZ IDs
suppressMessages(library("pheatmap"))      # Used to create heatmap
suppressMessages(library("RColorBrewer"))  # Color palette for heatmap
suppressMessages(library("org.Mm.eg.db"))  # Species database

#############################################################################
#                        Command Line Arguments                             #
#############################################################################

# set parsers for all input arguments
parser <- arg_parser("Generally Applicable Gene-set/Pathway Analysis parameters:")

# General Paeameters
parser <- add_argument(parser, "--dbrdata",
                       help = "Downloaded GEO dataset full path")
parser <- add_argument(parser, "--rundir",
                       help = "The output directory where graphs get saved")
parser <- add_argument(parser, "--dev", flag = TRUE, short = '-d',
                       help = "verbose version")

# Sample Parameters
parser <- add_argument(parser, "--popA",
                       help = "GroupA - all the selected phenotypes (atleast one)",
                       nargs = "+")
parser <- add_argument(parser, "--popB",
                       help = "GroupB - all the selected phenotypes (atleast one)",
                       nargs = "+")
parser <- add_argument(parser, "--factor",
                       help = "Factor type to be classified by")

# Gage Parameters
parser <- add_argument(parser, "--comparisontype", help = "ExpVsCtrl or ExpVsExp")
parser <- add_argument(parser, "--genesettype",
                       help = "KEGG - KEGG Database or
                       BP - GO Biological Process or
                       MF - GO molecular function
                       or CC - Cellular Component")

# Heatmap
parser <- add_argument(parser, "--heatmaprows",
                       help = "Number of genes show in the heatmap")
parser <- add_argument(parser, "--dendrow", flag = TRUE,
                       help = "Flag to display dendogram for Genes")
parser <- add_argument(parser, "--dendcol", flag = TRUE,
                       help = "Flag to display dendogram for Samples")
parser <- add_argument(parser, "--clusterby",
                       help = "Cluster based complete dataset or toptable")
# Clustering
parser <- add_argument(parser, "--distance",
                       help = "Distance measurement methods")
parser <- add_argument(parser, "--clustering",
                       help = "HCA clustering methods")


# allows arguments to be run via the command line
argv <- parse_args(parser)

##############################################################################
#                         Command Line Arguments Retrieval                   #
##############################################################################
split_arg <- function(vector_arg) {
  pos <- unlist(gregexpr("[^\\\\],", vector_arg, perl=TRUE))
  vect <- substring(vector_arg, c(1, pos+2), c(pos, nchar(vector_arg)))
  vect <- gsub("\\\\,", ",", vect) # replace \\, with ,
  vect <- gsub("\\\"", '"', vect) #replace \" with "
  vect <- gsub('\\\\-', '-', vect) # replace \\- with -
  return (vect)
}

# General Parameters
run.dir     <- argv$rundir
dbrdata     <- argv$dbrdata
isdebug     <- argv$dev

# Sample Parameters
factor.type <- as.character(argv$factor)
population1 <- split_arg(argv$popA)
population2 <- split_arg(argv$popB)
pop.colour1     <- "#b71c1c"  # Red
pop.colour2     <- "#0d47a1"  # Blue

# Heatmap
heatmap.rows <- as.numeric(argv$heatmaprows)
dendrow      <- as.logical(argv$dendrow)
dendcol      <- as.logical(argv$dendcol)
cluster.by   <- argv$clusterby

# Clustering
dist.opt    <- c("euclidean", "maximum", "manhattan", "canberra", "binary",
                 "minkowski")
dist.method <- ifelse(argv$distance %in% dist.opt, argv$distance, "euclidean")

clust.opt    <- c("ward.D", "ward.D2", "single", "complete", "average",
                  "mcquitty", "median", "centroid")
clust.method <- ifelse(argv$clustering %in% clust.opt, argv$clustering,
                       "average")

# Gage parameters
comparison.type <- argv$comparisontype  # "ExpVsCtrl" or "ExpVsExp"
geneset.type    <- argv$genesettype     # "KEGG"  or "BP" or "MF" or "CC"

#############################################################################
#                          Load Functions                                   #
#############################################################################

# Check if the run directory exists and if not, create directory...
check.run.dir <- function(run.dir) {
  if (!dir.exists(file.path(run.dir))) {
    dir.create(file.path(run.dir))
  }
}

###
## Heatmap
###

# Calculate Outliers Probabilities/ Dissimilarities
outlier.probability <- function(X, dist.method = "euclidean",
                                clust.method = "average") {
  # Rank outliers using distance and clustering parameters
  o <- outliers.ranking(t(X),test.data = NULL, method.pars = NULL,
                        method = "sizeDiff", # Outlier finding method
                        clus = list(dist = dist.method,
                                    alg  = "hclust",
                                    meth = clust.method))
  if (isdebug) print("GAGE: Outliers have been identified")
  return(o$prob.outliers)
}

get.heatmap <- function(analysis.stats, analysis.type) {
  analysis.heatmap <- t(analysis.stats)
  analysis.heatmap <- analysis.heatmap
  row.names(analysis.heatmap) <- gsub("(stats.)", "", row.names(analysis.heatmap))

  col.pal <- colorRampPalette(rev(RColorBrewer::brewer.pal(11, "RdYlGn")))(100)

  if (analysis.type == "ExpVsCtrl") { # Remove control group (Group 2)
    X.mat    <- X[,Group1]
    exp.info <- expression.info[expression.info[,"population"]== "Group1", ]
  } else {
    X.mat    <- X
    exp.info <- expression.info
  }

  # Column dendogram
  if (dendcol == TRUE) {
    # calculate heirachical clustering
    hc <- hclust(dist(t(X.mat), method = dist.method), method = clust.method)

    # Find outlier ranking/ probability
    outliers <- outlier.probability(X.mat, dist.method, clust.method)

    # Annotation columns
    ann.col <- data.frame(Population    = exp.info[, "population"],
                          Factor        = exp.info[, "factor.type"],
                          Dissimilarity = outliers)
    colnames(ann.col) <- c("Population", factor.type,"Dissimilarity")
  } else {
    hc <- FALSE
    # Annotation columns
    ann.col <- data.frame(Population    = exp.info[, "population"],
                          Factor        = exp.info[, "factor.type"])
    colnames(ann.col) <- c("Population", factor.type)
  }

  trans.analysis <- t(analysis.heatmap)
  if (nrow(trans.analysis) < heatmap.rows) {
    hdata <- trans.analysis                    # Show all
  } else {
    hdata <- trans.analysis[1:heatmap.rows, ]  # Limit to user specified limit
  }

  filename <- file.path(run.dir, "gage_heatmap.svg")
  CairoSVG(file = filename)
  pheatmap(hdata,
           cluster_row    = dendrow,
           cluster_cols   = hc,
           annotation_col = ann.col,
           color          = col.pal,
           fontsize       = 6.5,
           fontsize_row   = 3.0,
           fontsize_col   = 3.5)
  dev.off()

  if (isdebug) print(paste("GAGE: Saved heatmap", filename))
}

###
## GAGE ANALYSIS
###

gage.analysis <- function(set.type, analysis.type = "ExpVsCtrl", ref.group = G2,
                          samp.group = G1, compare.option = "unpaired") {
  analysis <- gage(geo.dataset, gsets = set.type, ref = G2, samp = G1,
                   same.dir = F, compare = compare.option )

  # Returns number of two-direction significantly enriched gene sets
  analysis.sig <- sigGeneSet(analysis)

  if (nrow(analysis.sig$greater) < 0) {
    cat("ERROR: No Significant Results Found!", file=stderr())
    quit(save = "no", status = 1, runLast = FALSE)
  } else {
    # Formatting and preparation for heatmap
    analysis.sig <- as.data.frame(analysis.sig)
    analysis.stats <- analysis.sig[, grep("^stats.GSM",names(analysis.sig),
                                          value = TRUE)]

    # Split each pathway names into pathway ID and pathway name
    m <- regmatches(rownames(analysis.sig),
                    regexpr(" ", rownames(analysis.sig)), invert = TRUE)
    # take each path, split into two and unlist them
    pathway.id   <- unlist(lapply(1:length(m),function(n) split(m[[n]][1], " ")))
    pathway.name <- unlist(lapply(1:length(m),function(n) split(m[[n]][2], " ")))
    rownames(analysis.stats) <- pathway.id

    analysis.results<- analysis$greater

    # Remove gene sets without zero enrichments
    analysis.results <- analysis.results[complete.cases(analysis.results), ]

    # Extract Pathway ID and Names
    m <- regmatches(rownames(analysis.results),
                    regexpr(" ", rownames(analysis.results)), invert = TRUE)
    # take each path, split into two and unlist them
    pathway.id   <- unlist(lapply(1:length(m), function(n) split(m[[n]][1], " ")))
    pathway.name <- unlist(lapply(1:length(m), function(n) split(m[[n]][2], " ")))

    # Create top table
    colnames(analysis.results)
    toptable <- data.frame(pathway.id, pathway.name, analysis.results[,1:5])
    toptable <- toptable[order(toptable$p.val),]
    rownames(toptable) <- NULL
    colnames(toptable) <- NULL

    # save "Toptable"
    filename <- file.path(run.dir, "gage_data.json")
    write(toJSON(list(tops = toptable), digits=I(4)), filename)

    # save toptable to a tab delimited file
    colnames(toptable) <- c("PathwayID", "Pathway", "PGeomean", "StatMean",
                            "PValue", "QValue", "SetSize")
    filename <- file.path(run.dir, "gage_toptable.tsv")
    write.table(toptable, filename, col.names=NA, sep = "\t" )

    # Creating a heatmap
    get.heatmap(analysis.stats, analysis.type)

    filename <- file.path(run.dir, "gage.RData")
    save( analysis.type, geo.dataset, analysis, geneset.type,
          Group1, Group1names, Group2, Group2names,
          organism.scientific.name, file = filename)
    }
  }

#############################################################################
#                        Load GEO Dataset to Start Analysis                 #
#############################################################################

if (file.exists(dbrdata)) {
  if (isdebug) print("GAGE: Loading Database data.")
  load(file = dbrdata)
} else {
  cat("ERROR: Data input error. Provide valid GDS dataset!", file=stderr())
  quit(save = "no", status = 200, runLast = FALSE)
}

check.run.dir(run.dir)

#############################################################################
#                        Two Population Preparation                         #
#############################################################################

if (isdebug) print(paste("GAGE: Factor :", factor.type))

# Phenotype Selection
pclass           <- pData[factor.type]
colnames(pclass) <- "factor.type"

# Create a data frame with the factors
expression.info  <- data.frame(pclass,
                               Sample = rownames(pclass),
                               row.names = rownames(pclass))

# Introduce two columns to expression.info :
#   1. population - new two groups/populations
#   2. population.colour - colour for two new two groups/populations
expression.info <- within(expression.info, {
    population        <- ifelse(factor.type %in% population1, "Group1",
                                ifelse(factor.type %in% population2, "Group2", NA))
    population.colour <- ifelse(factor.type %in% population1, pop.colour1,
                                ifelse(factor.type %in% population2, pop.colour2,
                                       "#000000"))
})

# Convert population column to a factor
expression.info$population <- as.factor(expression.info$population)

# Remove samples that are not belongs to two populations
expression.info <- expression.info[complete.cases(expression.info), ]
X <- X[, (colnames(X) %in% rownames(expression.info))]

# Get sample indexes and sample names
Group1 <-  which(expression.info[, "population"] == "Group1")
Group1names <- expression.info[Group1, "Sample"]

Group2 <-  which(expression.info[, "population"] == "Group2")
Group2names <- expression.info[Group2, "Sample"]

if (isdebug) print("GAGE: Factors and Populations have been set")

#############################################################################
#                            Data Preparation                               #
#############################################################################

geo.dataset <- X
rownames(geo.dataset) <- entrez.gene.id

if (isdebug) print("GAGE: Data Preparation completed")

#############################################################################
#                          Gage  Data Loading                               #
#############################################################################
# Loading data on kegg packages and species
if (geneset.type == "KEGG") { # KEGG datasets
  data(kegg.gs)
  kg.org <- kegg.gsets(organism)                 # picks out orgamism gene sets
  dbdata <- kg.org$kg.sets[kg.org$sigmet.idx]
} else { # GO Datasets
  go.hs <- go.gsets(species = organism.common.name)        # use species column of bods
  if (geneset.type == "BP") {                     # BP = Biological Process
    dbdata <- go.hs$go.sets[go.hs$go.subs$BP]
  } else if (geneset.type == "MF") {              # MF = molecular function
    dbdata <- go.hs$go.sets[go.hs$go.subs$MF]
  } else if (geneset.type == "CC") {              # CC = cellular component
    dbdata <- go.hs$go.sets[go.hs$go.subs$CC]
  }
}

#############################################################################
#                        Function Calling                                   #
#############################################################################

if (isdebug) { print("GAGE: GAGE analysis starting...") }
compare.option <- ifelse(comparison.type =="ExpVsCtrl", "unpaired", "paired")

if (comparison.type =="ExpVsCtrl") {
  G1 <- Group1
  G2 <- Group2
} else {
  G1 <- NULL
  G2 <- NULL
}

gage.analysis(dbdata, comparison.type, G2, G1, compare.option)

if (isdebug) print("GAGE analysis completed!")
