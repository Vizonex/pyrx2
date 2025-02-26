PYRX2
-----

A Forked Version of the original PYRX for Mining Monero & Other Crypto Currencies as well as being used 
for Malware research. It was my intent and goal to understand how cryptojacking works and why the original
library made kind of sucked at delivering what people may have been looking for. There were many limitations
with the original which is why I said enough was enough so I made a better one. 


## Changes Made From the Original Version

- Code is now written in `Cython` instead of in `C/C++/pybind11` making the library easier to maintain and safer to 
  install without requiring jack-shit or specific things to install.

- `RXMiner` class is designed to be isolated for use with multiprocessing. No More static Global Variables

- __Windows__ is no longer bound to requiring __WSL__ , __cmake__ and the __git__ command which was a deterrent for many developers from using the original PYRX library.

- __OpenMP__ ([Cython's Parallel Library](https://cython.readthedocs.io/en/latest/src/userguide/parallelism.html)) is used in trade of windows-threads and pthreads directly.

- `setup.py` Compiles RandomX Directly instead of via-cmake

## Requirements
- Visual Studio C/C++ Extension if your on Windows and you 
wish to compile this yourself
- `3.9+` is supported. Older Versions are discouraged because I don't program on them.

```python
from pyrx2 import RXMiner, RXFlags, get_flags
import binascii

seed_hash = binascii.unhexlify('63eceef7919087068ac5d1b7faffa23fc90a58ad0ca89ecb224a2ef7ba282d48')


def main():
    # Obtain Default Flags
    flags = get_flags()

    # Example if we wanted 2 mining threads & Cutsom Flags 
    # (Custom flags is Optional)
    miner = RXMiner(flags, 2)
    seed_height = 1
    print("mining...")
    output = miner.mine(b'my input', seed_hash, seed_height)
    print(binascii.hexlify(output).decode('utf-8'))

if __name__ == "__main__":
    main()

```

## Pull Requests Are Welcome
- There's a lot of limitations on my plate so any suggestions and pull requests are welcome. 


## Todos
- [ ] pypi release
- [ ] testing pyrx2
- [ ] There's a possibility to turn it into an optional Cython Extension as well.
