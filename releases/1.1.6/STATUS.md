# Avata 1.1.6 validation

The previous candidate passed Windows PowerShell 5.1 regression on commit `8cafad05ab2991aa6108c5ee95fc28c358a9da16`. Final review found a header-format range regression; the candidate now limits base-format extension and includes eight layout checks (74 asset checks; 800 total synthetic Windows checks planned). The corrected signed artifacts require a fresh CI run before publication. No live installation is claimed.
