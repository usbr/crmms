# ============================================================================
# Compare ESP forecasts from different months 
#   currently set-up only for Powell unreg but could be extended for other pts
#
# ============================================================================
rm(list=setdiff(ls(), c("scenario_dir", "scenarios", "fig_dir_nm")))

library(RWDataPlyr)
library(tidyverse)
library(lubridate)
library(rhdb)
library(zoo)

## -- Inputs if run alone
# source(file.path('Code', '0_MasterInputs.R'))

## Directories & Data
# Sys.getenv('CRMMS_DIR') # can be used to change directory to CRMMS_DIR
fig_dir <- file.path('Output Data', fig_dir_nm)
data_dir <- file.path('rdfOutput', scenario_dir)
dir.create(fig_dir, showWarnings = F)
source(file.path('Code', 'add_MeadPowell_tiers.R'))

## Max Date
max_date = '2026-12' #'2024-12'

slots = c("PowellInflow.Unregulated")
file_nm_end <- paste0('_thru', format(ym(max_date), "%Y"))

## -- Read in CRMMS results

# slots/agg to read
rwa1 <- rwd_agg(data.frame(
  file = rep('streamflow.rdf', length(slots)),
  slot = slots, 
  period = rep("asis", length(slots)),
  summary = rep(NA, length(slots)),
  eval = rep(NA, length(slots)),
  t_s = rep(NA, length(slots)),
  variable = slots,
  stringsAsFactors = FALSE
))

# read/process RDFs
df <- NULL
for (i in 1:length(scenarios)) {
  scen_res <- rdf_aggregate(  
    agg = rwa1, 
    rdf_dir = data_dir[i],
    keep_cols = 'Unit'
  )
  scen_res$Scenario <- scenarios[i]
  
  # keep only last 30 traces (ESP)
  trces = unique(scen_res$TraceNumber)
  tr_keep = trces[(length(trces)-29):length(trces)]
  scen_res = scen_res %>% filter(TraceNumber %in% tr_keep)
  
  df <- rbind(df, scen_res)
}

df_scens <- data.table::as.data.table(df)  %>% 
  mutate(Date = as.yearmon(paste0(Month, Year), "%B%Y")) %>%
  select(Scenario, Variable, Date, Trace = TraceNumber, Value) %>%
  filter(Date <= as.yearmon(format(ym(max_date), "%Y-%m"))) %>%
  mutate(Scenario = factor(Scenario, levels = scenarios),
         wy = ifelse(month(Date) >= 10,
                     year(Date) + 1, year(Date))) 

## Read Powell fcst csv from CBRFC website: https://www.cbrfc.noaa.gov/outgoing/ucbor/
# scenario_add = 'May 22'
# newFcst = read.csv('C:/Users/sabaker/Downloads/GLDA3.espmvol.5yr.adj.csv', skip = 2, header = T)
# traceVals = as.character(4:33)
# colnames(newFcst) <- c('Date', traceVals)
# df_add = newFcst %>% pivot_longer(cols = traceVals, names_to = 'Trace', values_to = 'Value') %>%
#   mutate(Date = as.yearmon(lubridate::my(Date), "%b-%y"),
#          Scenario = scenario_add,
#          wy = ifelse(month(Date) >= 10,
#                      year(Date) + 1, year(Date)),
#          Variable = slots) %>%
#   select(colnames(df_scens))
# df_scens = rbind(df_scens, df_add)
# scenarios = c(scenario_add, scenarios)


## Read historical data from hdb
sdis <- c("PowellInflow.Unregulated" = 1856)
start_date = format(ym("1990-10"), "%Y-%m")
dt_fcst = df_scens %>% group_by(Scenario) %>% summarise(dt = min(Date))
end_date = format(max(dt_fcst$dt) - 1/12, "%Y-%m") 

df_hdb <- bind_rows(
  hdb_query(sdis["PowellInflow.Unregulated"], "uc", "m", start_date, end_date)
)

df_hdb <- df_hdb %>%
  mutate(Variable = names(sdis)[match(sdi, sdis)],
         Date = as.yearmon(parse_date_time(time_step, "m/d/y H:M:S")),
         wy = ifelse(month(Date) >= 10,
                        year(Date) + 1, year(Date)),
         value = value/1000)

df_clim <- df_hdb %>%
  filter(wy %in% 1991:2020) %>%
  group_by(Variable) %>%
  summarise(ann = mean(value)*12) 

# Add historical data to model projections
for (i in 1:length(scenarios)) {
  df_scensI = df_scens %>% filter(Scenario == scenarios[i]) 
  df_histAdd <- df_hdb %>% 
    filter(wy %in% min(df_scensI$wy) & 
             Date < min(df_scensI$Date)) %>%
    select(Variable, Date, wy, Value = value)
  
  df_add <- df_scensI %>% 
    filter(wy %in% min(df_scensI$wy)) %>% 
    select(Scenario, Variable, Trace, wy) %>% distinct()
  
  addHist = left_join(df_histAdd, df_add, by = c("wy", "Variable")) %>%
    select(colnames(df_scens))
  
  df_scens = rbind.data.frame(df_scens, addHist)
}

df_ann = df_scens %>%
  group_by(Scenario, Variable, Trace, wy) %>%
  # summarise(ann_wy = sum(Value)) %>%
  summarise(ann_wy = sum(Value), 
            n = n()) %>%
  left_join(df_clim, by = 'Variable') %>%
  mutate(POA = ann_wy/ann*100) %>%
  filter(wy <= year(ym(max_date)))

# check that there are 12 months for each year
if (any(df_ann$n != 12)) {
  warning('Some scenarios/WYs do not have 12 entries')
  df_ann = df_ann %>% filter(n == 12)
}

ggplot(df_ann, aes(factor(wy), ann_wy, fill = Scenario)) +
  CRSSIO::stat_boxplot_custom() +
  bor_theme() +
  # geom_hline(yintercept = 9603.36, color = 'grey', linetype = 'dashed') +
  labs(y = 'Lake Powell Unreg. Inflow (kaf)', x = 'WY')

ggsave(file = file.path(fig_dir, paste0(slots, '_WY', file_nm_end, '.png')),
       height = 6, width = 7)


## current WY
df_ann %>% 
  filter(wy == min(df_ann$wy)) %>%
  ggplot() +
  bor_theme() +
  stat_ecdf(aes(x=ann_wy, color= Scenario)) +
  labs(y = 'f(x)', x = 'Unregulated Inflow (kaf)',
       title = paste('CDF of WY', min(df_ann$wy), 'Lake Powell Unregulated Inflow'))+
  scale_y_continuous(breaks = seq(0,1,by = .1), limits = c(0,1), expand = c(0,0)) +
  scale_x_continuous(labels = scales::comma) 
ggsave(file = file.path(fig_dir, paste0(slots, '_CDF_WY', min(df_ann$wy), '.png')),
       height = 6, width = 8)

# next wy
wyI = min(df_ann$wy)+1
df_ann %>% 
  filter(wy == wyI ) %>%
  ggplot() +
  bor_theme() +
  stat_ecdf(aes(x=ann_wy, color= Scenario)) +
  labs(y = 'f(x)', x = 'Unregulated Inflow (kaf)',
       title = paste('CDF of WY', wyI , 'Lake Powell Unregulated Inflow'))+
  scale_y_continuous(breaks = seq(0,1,by = .1), limits = c(0,1), expand = c(0,0)) +
  scale_x_continuous(labels = scales::comma) 
ggsave(file = file.path(fig_dir, paste0(slots, '_CDF_WY', wyI, '.png')),
       height = 6, width = 8)

# average of wy annuals
df_ann %>% 
  group_by(Scenario, wy) %>%
  # summarise(avgI = mean(ann_wy)) %>% 
  summarise(avgI = quantile(ann_wy,0.5)) %>% 
  ungroup() %>%
  pivot_wider(names_from = Scenario, values_from = avgI)

