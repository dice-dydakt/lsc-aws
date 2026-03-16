import numpy as np


def generate_dataset(n=50000, dim=128, seed=0):
    """Generate a deterministic dataset of n vectors with given dimensionality."""
    rng = np.random.RandomState(seed)
    return rng.randn(n, dim).astype(np.float32)
