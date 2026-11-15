"""Test stand-in for PyTorch (CPU only)."""
float16, float32 = "float16", "float32"


class cuda:  # noqa: N801
    @staticmethod
    def is_available():
        return False

    @staticmethod
    def empty_cache():
        pass

    @staticmethod
    def max_memory_allocated():
        return 0
