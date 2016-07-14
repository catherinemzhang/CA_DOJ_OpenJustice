
## Prep the workspace
library("AzureML")
ws <- workspace()

## load the data: Read all arrests files and merge into one massive data frame.
## Please note: We could automate file name detection/grabbing in a local version of this, but we're
## trying to lean on Azure ML's processing power, so we've gotta' work with their obfuscation of
## dataset paths.
file_names <- grep("^ca_doj_arrests.*csv", ws$datasets$Name, value = T)

## Subset to only 2005-2014, because our population data only begins in 2005
dat_arrests <- do.call(rbind, download.datasets(ws, file_names[!grepl("200[0-4]", file_names)]))

## Remove row names
row.names(dat_arrests) <- NULL

## Then, get county population data by race and gender.
dat_pop <- download.datasets(ws, "ca_county_population_by_race_gender_age_2005-2014_02-05-2016.csv")

## Preview the arrests data
dim(dat_arrests)
names(dat_arrests)
head(dat_arrests, 3)

## Load necessary libraries
library(dplyr)
library(ggplot2)
library(grid)
library(stats)

## Subset arrests to only juveniles.
dat_juv <- dat_arrests[dat_arrests$age_group %in% "juvenile",]

## Group by county, then by year, then by race/ethnicity and give me the counts.
cty_ethnic <- summarise(group_by(dat_juv, county, arrest_year, race_or_ethnicity), total = n())

## Now remove those records supressed due to privacy concern.
cty_ethnic <- cty_ethnic[!(cty_ethnic$race_or_ethnicity %in% "suppressed_due_to_privacy_concern"),]

#### !! Some counties are reporting only "NA"s in their arrest totals per ethnic group. :-\
## Let's remove those from our analysis...for now.
cty_ethnic <- cty_ethnic[!is.na(cty_ethnic$total),]

## Confirm via preview
dim(cty_ethnic)
head(cty_ethnic)
tail(cty_ethnic)

## Panel bar charts: ethnic breakdown of arrests, by county.
## Note: this is sheerly by count (not rate).
plot_ethnic <- ggplot(cty_ethnic[cty_ethnic$arrest_year %in% "2014",], aes(x = race_or_ethnicity, y = total, fill = race_or_ethnicity)) + 
                geom_bar(stat = "identity") + coord_flip() + facet_wrap(~county) +  
                theme(axis.text.x=element_text(angle=-90,hjust=1,vjust=0.5, size = 8), axis.text.x=element_text(size = 8),
                      legend.position = "none", strip.text=element_text(size = 8), axis.title.x=element_blank(),
                      axis.title.y=element_blank()) +
                ggtitle("Ethnic Breakdown of Arrest FREQ by County\r
2014 Only (test year)")

## Print plot
plot_ethnic

## Stacked bar chart: ethnic breakdown of arrests, stacked between counties.
plot_ethnic2 <- ggplot(cty_ethnic[cty_ethnic$arrest_year %in% "2014",], aes(x = race_or_ethnicity, y = total, fill = county)) + 
                geom_bar(stat = "identity") + coord_flip() + 
                theme(axis.text.x=element_text(angle=-90,hjust=1,vjust=0.5, size = 8), axis.text.x=element_text(size = 8),
                      strip.text=element_text(size = 8), axis.title.x=element_blank(), axis.title.y=element_blank(),
                      legend.text=element_text(size= 6), legend.key.height=unit(.4, "cm")) +
                ggtitle("Cumulative Ethnic Breakdown of Arrest Freq by County\r
2014 Only (test year)")

## Print plot
plot_ethnic2

## Now, let's preview the population data
dim(dat_pop)
names(dat_pop)
head(dat_pop)

## Looks like it's already aggregated along a number of dimensions. 
## Let's subset only the juveniles.
dat_pop_jv <- dat_pop[dat_pop$age_group %in% "Juvenile",]

## Ok, now, let's look at arrests of both genders and ignore the 'all combined' county value.
dat_pop_jv <- dat_pop_jv[dat_pop_jv$gender %in% "All Combined" & !(dat_pop_jv$county %in% "All Combined"),]

## Let's also remove the race 'all combined.'
dat_pop_jv <- dat_pop_jv[!(dat_pop_jv$race %in% "All Combined"),]

## Confirm we did this right by previewing the head and tail.
head(dat_pop_jv)
tail(dat_pop_jv)

## Show the race / ethnicity categories of each dataset (arrests vs. population)
unique(dat_juv$race_or_ethnicity)
unique(dat_pop_jv$race)

## Join the pop and arrests datasets.
## Start by relabeling the 'race' variable in the pop table. Also, until we've bound all years together, 
names(dat_pop_jv)[3] <- "race_or_ethnicity"
names(cty_ethnic)[2] <- "year"
dat_joined <- right_join(cty_ethnic, dat_pop_jv, by = c("county","year","race_or_ethnicity"))

## Let's sub out those counties that aren't represented in the arrests file.
dat_joined <- dat_joined[!(dat_joined$county %in% "Alpine" | 
                           dat_joined$county %in% "Amador" |
                           dat_joined$county %in% "Yuba"),]

## Preview to confirm. 
head(dat_joined)
tail(dat_joined)

## Let's remove post-join arrest total NAs from our analysis...for now.
dat_joined <- dat_joined[!is.na(dat_joined$total),]

## Actually add a column just for arrest rate by ethnic population per county.
dat_joined$eth_arrest_rate <- round((dat_joined$total)/(dat_joined$population), 5)

## Now, let's panel plot arrest rates by county.
plot_ethnic_norm <- ggplot(dat_joined[!(dat_joined$race_or_ethnicity %in% "Native American") & dat_joined$year %in% "2014",], 
                        aes(x = race_or_ethnicity, y = eth_arrest_rate, fill = race_or_ethnicity), na.rm=T) + 
                        geom_bar(stat = "identity") + coord_flip() + facet_wrap(~county) +  
                        theme(axis.text.x=element_text(angle=-90,hjust=1,vjust=0.5, size = 8), axis.text.x=element_text(size = 8),
                        legend.position = "none", strip.text=element_text(size = 8), axis.title.x=element_blank(),
                        axis.title.y=element_blank()) +
                        ggtitle("Ethnic Breakdown of Arrest Rates by County\r
-2014 Only-")

## Print plot
plot_ethnic_norm

#### Looping approach (Please don't hate me, Rocio! I'll vectorize asap :)) ####

## Create empty dataframe
dat_stats <- dat_joined[0,]
dat_stats$rate_prob <- numeric(0)
dat_stats$z_score <- numeric(0)

## Nested loop (computing stats per race/ethnic group, per year)
for(i in unique(dat_joined$year)){
    
    ## Subset to iterative year
    dat_year <- dat_joined[dat_joined$year %in% i,]
    
    for(j in unique(dat_year$race_or_ethnicity)){
        
        ## Subset to iterative race/ethnicity
        dat_race <- dat_year[dat_year$race_or_ethnicity %in% j,]
        
        ## Compute the probability of the observed arrest rate
        dat_race$rate_prob <- round(pnorm(dat_race$eth_arrest_rate, mean(dat_race$eth_arrest_rate, na.rm = T), 
                                    sd(dat_race$eth_arrest_rate, na.rm = T), lower.tail = FALSE, log.p = FALSE), 5)
        
        ## Compute the Z-score of the observed arrest rates
        dat_race$z_score <- qnorm(dat_race$rate_prob, lower.tail = FALSE, log.p = FALSE)
        
        ## Bind to burgeoning dataframe
        dat_stats <- rbind(dat_stats, dat_race)
    }
}

## Now, preview those who have evidently been outliers in enforcement upon every ethnic group per every year.
paste("Number of outlying instances over this time-span:", nrow(dat_stats[dat_stats$z_score >= 2,]))
head(dat_stats[dat_stats$z_score >= 2,], 20)
head(dat_stats[dat_stats$z_score >= 2,], 20)

## Draw up a frequency table of the instances per outlying county from above.
table(dat_stats[dat_stats$z_score >= 2, "county"])

## Isolate Kings cases to see if there's a pattern.
dat_stats[dat_stats$z_score >= 2 & dat_stats$county %in% "Kings",]

## Let's isolate those SF cases to see if there's a pattern there.
dat_stats[dat_stats$z_score >= 2 & dat_stats$county %in% "San Francisco",]

## Choose a test subset
dat_stats_test <- dat_stats[dat_stats$year %in% "2014" & dat_stats$race_or_ethnicity %in% "Hispanic",]

## Test for difference between observed distribution and normal distribution (Shapiro-Wilk normality test). 
## If difference's p is < .05, then the observed distribution is not sufficiently normal.
shapiro.test(dat_stats_test$eth_arrest_rate)

## See what happens if we exclude the outliers. Depending on the number of outliers, this should
## be even closer to normal.
shapiro.test(dat_stats_test$eth_arrest_rate[dat_stats_test$z_score < 2])

## Plot the density w/outliers
plot(density(dat_stats_test$eth_arrest_rate), 
     main = "Arrest Rate Density for Hispanics in 2014\r
(test eth and year), With Outliers")

## Plot vs. purely normal distribution
qqnorm(dat_stats_test$eth_arrest_rate, main = "Arrest Rate Observations for Hispanics in 2014\r
vs. Theoretical Normal Quantiles (outliers included)")
qqline(dat_stats_test$eth_arrest_rate)

## Upload full stats DF to Azure ML and save to local csv.
upload.dataset(dat_stats, ws, name = "jv-ethnic-arrests_stats_2005-2014")
write.csv(dat_stats, "jv-ethnic-arrests_stats_2005-2014.csv", row.names = F)

## Upload outliers DF to Azure ML and save to local csv.
upload.dataset(dat_stats[dat_stats$z_score > 2,], ws, name = "jv-ethnic-arrests_outliers_2005-2014")
write.csv(dat_stats, "jv-ethnic-arrests_outliers_2005-2014.csv", row.names = F)

## ^Please disregard the Azure ML upload status messages the system produces...

# ## Note to self: Window function / vectorization approach (for practice! - not done yet)
# 
# prob_fun <- function(x){
#     round(pnorm(x, mean(x, na.rm = T), sd(x, na.rm = T), lower.tail = FALSE, log.p = FALSE), 5)
# }
# zscore_fun <- function(x){
#     round(qnorm(x$rate_prob, lower.tail = FALSE, log.p = FALSE), 5)
# }
# 
# dat_wstats <- aggregate(eth_arrest_rate ~ year + county, data = dat_joined, FUN = prob_fun, na.action = "na.pass")
# 
# #dat_wstats
# names(dat_wstats)[3] <- "rate_prob"
# 
# dat_wstats
