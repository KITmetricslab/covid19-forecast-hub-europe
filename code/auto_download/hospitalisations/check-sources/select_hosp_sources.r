library("readr")
library("dplyr")
library("here")
library("lubridate")
library("ggplot2")
library("janitor")
library("tidyr")

scraped_files <- list.files("data", pattern = "COVID-")
official_files <- list.files("data", pattern = "official-")

scraped <- list()
official <- list()

for (file in scraped_files) {
  file_date <- sub("^.*(202[0-9]-[0-9]+-[0-9]+).*$", "\\1", file)
  scraped[[file_date]] <- read_csv(here::here("data", file)) %>%
    clean_names() %>%
    mutate(download_date = as.Date(file_date))
}

pop <- scraped[[length(scraped)]] %>%
  select(location_name = country_name, population) %>%
  distinct()

scraped <- scraped %>%
  bind_rows() %>%
  filter(indicator == "New_Hospitalised") %>%
  select(download_date, location_name = country_name, date, source, value) %>%
  mutate(source = if_else(grepl("TESSy", source), "TESSy", "Public"),
         type = "Scraped")

for (file in official_files) {
  file_date <- sub("^.*(202[0-9]-[0-9]+-[0-9]+).*$", "\\1", file)
  official[[file_date]] <- read_csv(here::here("data", file)) %>%
    mutate(download_date = as.Date(file_date))
}

official <- official %>%
  bind_rows() %>%
  rename(location_name = country) %>%
  inner_join(pop, by = "location_name") %>%
  rename(unscaled_value = value) %>%
  filter(grepl("hospital admissions", indicator)) %>%
  mutate(value = if_else(grepl("100k", indicator),
                         round(unscaled_value * population / 1e+5),
                         unscaled_value)) %>%
  select(download_date, location_name, date, value, source) %>%
  mutate(source = if_else(grepl("TESSy", source), "TESSy", "Public"),
         type = "ECDC")

scraped_weekly <- scraped %>%
  mutate(week_end = ceiling_date(date, unit = "week", week_start = 7)) %>%
  group_by(location_name, date = week_end, source, type, download_date) %>%
  summarise(value = sum(value), n = n(), .groups = "drop") %>%
  filter(n == 7) %>%
  select(-n)

all <- official %>%
  bind_rows(scraped_weekly) %>%
  filter(date >= "2021-05-01") %>%
  ## download delay in days
  mutate(download_delay = as.integer(download_date - date)) %>%
  ## download_delay in weeks
  mutate(download_delay = ceiling(download_delay / 7))

delays <- all %>%
  select(-download_date) %>%
  group_by(location_name, date, source, type) %>%
  mutate(final_value = value[which.max(download_delay)]) %>%
  ungroup() %>%
  mutate(rel_diff = (final_value - value) / final_value)

## don't use delays that would have recently resulted in final relative differences of >5%
dont_use <- delays %>%
  filter(date >= "2021-10-10", rel_diff > 0.05) %>%
  select(location_name, source, type, download_delay) %>%
  distinct() %>%
  arrange(location_name)

## filter out delays with unacceptable revisions
filtered <- all %>%
  anti_join(dont_use, by = c("location_name", "source", "type", "download_delay")) %>%
  group_by(location_name) %>%
  filter(date == max(date))

## filter out delays of > 2 weeks
filtered <- filtered %>%
  filter(download_delay <= 2)

final_table <- filtered %>%
  select(location_name, source, type, truncate_weeks = download_delay) %>%
  ## sort to prefer: remove fewer weeks, Scraped over ECDC (because daily)
  arrange(location_name, truncate_weeks, desc(type)) %>%
  group_by(location_name) %>%
  ## take top choice in each country
  slice(1)

# remove some countries manually
exclude_locations <- c("Poland")
final_table <- final_table %>%
  filter(!location_name %in% exclude_locations)

write_csv(final_table, here::here("code", "auto_download", 
                                  "hospitalisations",  
                                  "check-sources", "sources.csv"))

## main plot: hospitalisation data
plot_data <- all %>%
  inner_join(final_table, by = c("location_name", "type")) %>%
  group_by(location_name) %>%
  filter(download_date == max(download_date)) %>%
  ungroup() %>%
  filter(download_delay >= truncate_weeks)

p <- ggplot(plot_data, aes(x = date, y = value, colour = type)) +
  scale_colour_brewer("", palette = "Set1") +
  facet_wrap(~location_name, scale = "free_y") +
  theme_minimal() +
  theme(legend.position = "bottom") +
  geom_point() +
  geom_line() +
  xlab("Last day of week shown (Saturday)") +
  ylab("Number of weekly hospitalisations")

ggsave(here::here("code", "auto_download", "hospitalisations.png"), p, width = 14, height = 10)
