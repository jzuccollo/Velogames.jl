# Velogames.jl

Hacky, personal Julia package to pick a Velogames team. Always in progress, always a bit broken, no guarantees it'll work anywhere else!

## Approach

Solve a linear programme to maximise expected points, constrained by budget and rider limits. Rider points are hacked together from a combination of PCS points and current Velogames standings and presently need manual attention for every race. This is probably the biggest thing that needs fixing before predictions can be trusted and automated.

## Usage

Outputs calculated in the Quarto files in the `race_notebooks/` directory. Quarto files are locally rendered to `docs/` with `quarto render` and [served with Pages](https://jzuccollo.github.io/Velogames.jl). 

No guarantee they'll re-render because they pull from the moving target of velogames.com rider pages, so URLs typically need to be updated for every render.

## Testing

Errr, not much. `Pkg.test()` should run the few tests that exist.