# Velogames.jl

Hacky, personal Julia package to pick a Velogames team. Always in progress, always a bit broken, no guarantees it'll work anywhere else!

## Approach

Solve a linear programme to maximise expected points, constrained by budget and rider limits. Rider points are hacked together from a combination of PCS points and current Velogames standings and presently need manual attention for every race. This is probably the biggest thing that needs fixing before predictions can be trusted and automated.

## Usage

Outputs calculated in the Quarto files in the `race_notebooks/` directory. Quarto files are locally rendered to `docs/` with `quarto render` and [served with Pages](https://jzuccollo.github.io/Velogames.jl).

No guarantee they'll re-render because they pull from the moving target of velogames.com rider pages, so URLs typically need to be updated for every render.

## Features

The analysis notebooks demonstrate several key features of the `Velogames.jl` package:

- **Multi-source data integration**: Combining VeloGames results, ProCyclingStats (PCS) rankings, and potentially other data sources like betting odds to create a comprehensive rider profile.
- **Automated race optimization**: The `solverace()` function can be used for different race types:
  - `:stage`: Automatically applies classification constraints for stage races (e.g., 2 all-rounders, 1 sprinter, 2 climbers, 3+ unclassed).
  - `:one_day`: Solves for a one-day race with no classification constraints.
- **Robust caching**: A flexible caching system (`CacheConfig`) stores downloaded data to speed up subsequent runs and handle historical analysis. Caches are timestamped and have a configurable expiry.
- **Strategy comparison**: The framework allows for easy testing of different data source weightings to see how predictions change based on how much you trust VG vs. PCS data.

## Testing

Errr, not much. `Pkg.test()` should run the few tests that exist.
