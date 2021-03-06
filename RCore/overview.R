#!/usr/bin/Rsript
# ---------------------------------------------------------#
# Filename      : DGEA.R                                   #
# Authors       : IsmailM, Nazrath, Suresh, Marian, Anisa  #
# Description   : Differential Gene Expression Analysis    #
# Usage         : Rscript overview.R --accession GDS5093 --dbrdata ~/Desktop/GDS5093.rData --rundir ~/Desktop/dgea/ --factor "disease.state" --popA "Dengue Hemorrhagic Fever,Convalescent,Dengue Fever" --popB "healthy control" --popname1 "Dengue" --popname2 "Normal" --analyse "Boxplot,PCA" --dev TRUE
# ---------------------------------------------------------#

#############################################################################
#                        Import Libraries                                   #
#############################################################################

# load required libraries and silence library loading messages on command line
suppressMessages(library("argparser"))     # Argument passing
suppressMessages(library("Cairo"))         # Plots saving
suppressMessages(library("dendextend"))    # Dendogram extended functionalities
suppressMessages(library("DMwR"))          # Outlier Prediction for clustering
suppressMessages(library("GEOquery"))      # GEO dataset Retrieval
suppressMessages(library("ggplot2"))       # Graphs designing
suppressMessages(library("jsonlite"))      # Convert R object to JSON format
suppressMessages(library("plyr"))          # Splitting, Applying and Combining Data
suppressMessages(library("RColorBrewer"))  # Import Colour Pallete
suppressMessages(library("reshape2"))      # Prepare dataset for ggplot
suppressMessages(library("squash"))        # Clustering Dendogram

#############################################################################
#                        Command Line Arguments                             #
#############################################################################

# set parsers for all input arguments
parser <- arg_parser("This parser contains the input arguments")

# General Parameters
parser <- add_argument(parser, "--rundir",
                       help = "The outout directory where graphs get saved")
parser <- add_argument(parser, "--dbrdata",
                       help = "Downloaded GEO dataset full path")
parser <- add_argument(parser, "--analyse", nargs = "+",
                       help = "List of analysis to be performed")
parser <- add_argument(parser, "--geodbpath",
                       help = "GEO Dataset full path")
parser <- add_argument(parser, "--dev", flag = TRUE, short = '-d',
                       help = "verbose version")

# Sample Parameters
parser <- add_argument(parser, "--factor",
                       help = "Factor type to be classified by")
parser <- add_argument(parser, "--popA", nargs = "+",
                       help = "Group A - all the selected phenotypes (at least one)")
parser <- add_argument(parser, "--popB", nargs = "+",
                       help = "Group B - all the selected phenotypes (at least one)")
parser <- add_argument(parser, "--popname1",
                       help = "name for Group A")
parser <- add_argument(parser, "--popname2",
                       help = "name for Group B")

# allow arguments to be run via the command line
argv   <- parse_args(parser)

#############################################################################
#                        Command Line Arguments Retrieval                   #
#############################################################################
split_arg <- function(vector_arg) {
  pos  <- unlist(gregexpr("[^\\\\],", vector_arg, perl=TRUE))
  vect <- substring(vector_arg, c(1, pos+2), c(pos, nchar(vector_arg)))
  vect <- gsub("\\\\,", ",", vect) # replace \\, with ,
  vect <- gsub("\\\"", '"', vect) # replace \" with "
  vect <- gsub('\\\\-', '-', vect) # replace \\- with -
  return (vect)
}

# General Parameters
run.dir         <- argv$rundir
dbrdata         <- argv$dbrdata
analysis.list   <- split_arg(argv$analyse)

# Sample Parameters
factor.type     <- argv$factor
population1     <- split_arg(argv$popA)
population2     <- split_arg(argv$popB)
pop.name1       <- argv$popname1
pop.name2       <- argv$popname2
pop.colour1     <- "#e199ff" # Purple
pop.colour2     <- "#96ca00" # Green

isdebug <- argv$dev

#############################################################################
#                          Load Functions                                   #
#############################################################################

# Check if the run directory exists and if not, create directory...
check.run.dir <- function(run.dir) {
  if (!dir.exists(file.path(run.dir))) {
    dir.create(file.path(run.dir))
  }
}

# Boxplot
samples.boxplot <- function(data, pop.colours, pop.names, path) {
  boxplot <- ggplot(data) + geom_boxplot(aes(x = Var2, y = value, colour = Groups), outlier.shape = NA) + theme(axis.text.x = element_text(angle = 70, hjust = 1), legend.position = "right")+ labs(x = "Samples", y = "Expression Levels") + scale_color_manual(name = "Groups", values = pop.colours, labels = pop.names)

  # compute lower and upper whiskers to set the y axis margin
  ylim1 = boxplot.stats(data$value)$stats[c(1, 5)]

  # scale y limits based on ylim1
  boxplot <- boxplot + coord_cartesian(ylim = ylim1*1.05)

  filename <- file.path(path, "boxplot.png")
  ggsave(filename, plot = boxplot, width = 8, height = 4)

  if (isdebug) print("Overview: Boxplot has been produced")
}

# Principal Component Analysis
get.pcdata <- function(Xpca) {
  s <- summary(Xpca)

  exp.var <- s$importance[2, ] * 100 # Explained Variance in percentages
  cum.var <- s$importance[3, ] * 100 # Cumulative Variance in percentages
  pcnames <- names(exp.var)          # PC names

  names(exp.var) <- NULL
  names(cum.var) <- NULL

  results <- list(pcnames = pcnames, expVar = exp.var, cumVar = cum.var)

  return(results)
}

get.pcplotdata <- function(Xpca, populations) {
  Xscores           <- Xpca$x
  sample.names      <- rownames(Xscores)
  rownames(Xscores) <- NULL
  cols              <- colnames(Xscores)

  # Take each column of Xscore (as temp variable y) and split based on the population
  Xscores <- lapply(1:nrow(Xscores),
                    function(y) split(Xscores[, y], populations))
  names(Xscores) <- cols

  # Unlist them but not to the dept. outer most list has unlisted
  pc             <- unlist(Xscores, recursive = FALSE)

  # Split sample names by population and add to the final list
  complete.data  <- c(split(sample.names, populations),pc)

  if (isdebug) print("Overview: PCA has been calculated")
  return(complete.data)
}


#############################################################################
#                        Load GEO Dataset to Start Analysis                 #
#############################################################################

if (file.exists(dbrdata)) {
  if (isdebug) print("Overview: Loading Database data.")
  load(file = dbrdata)
} else {
  cat("ERROR: Data input error. Provide valid GDS dataset!", file=stderr())
  quit(save = "no", status = 200, runLast = FALSE)
}

check.run.dir(run.dir)

#############################################################################
#                        Two Population Preparation                         #
#############################################################################
# Phenotype selection
pclass           <- pData[factor.type]
colnames(pclass) <- "factor.type"

# Create a data frame with the factors
expression.info  <- data.frame(pclass, Sample = rownames(pclass),
                               row.names = rownames(pclass))

# Introduce two columns to expression.info :
#   1. population - new two groups, if not NA
#   2. population.colour - colour for two new two groups, if not black colour
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

# Data preparation for ggplot-Boxplot
data <- within(melt(X), {
  phenotypes <- expression.info[Var2, "factor.type"]
  Groups     <- expression.info[Var2, "population.colour"]
})

if (isdebug) print("Overview: Factors and Populations have been set")

#############################################################################
#                        Function Calling                                 #
#############################################################################

json.list <- list()

if ("Boxplot" %in% analysis.list) {
  samples.boxplot(data, c(pop.colour2, pop.colour1),
                  c(pop.name2, pop.name1), path = run.dir)
}

if ("PCA" %in% analysis.list) {
  Xpca       <- prcomp(t(X))
  pcdata     <- get.pcdata(Xpca) # PC individual and cumulative values
  json.list  <- append(json.list, list(pc = pcdata))
  # PC scatter plot
  pcplotdata <- get.pcplotdata(Xpca, expression.info[, "population"])
  json.list  <- append(json.list, list(pcdata = pcplotdata)) # add to json list
}

if (length(json.list) != 0) {
  # Write to a json file with 4 decimal places
  filename <- file.path(run.dir, "data.json")
  write(toJSON(json.list, digits=I(4)), filename )
}
