# cython: language_level = 3
cimport cython
from cython.parallel import prange # type: ignore

from cpython.buffer cimport PyBUF_SIMPLE, PyObject_GetBuffer, PyBuffer_Release
from cpython.bytes cimport PyBytes_FromStringAndSize, PyBytes_AS_STRING
from cpython.exc cimport PyErr_NoMemory
from cpython.mem cimport PyMem_Malloc, PyMem_Free
from libc.stdint cimport uint64_t
from libc.string cimport memcpy, memcmp



cdef extern from "src/randomx.h" nogil:
    """
#define SEEDHASH_EPOCH_BLOCKS	2048	/* Must be same as BLOCKS_SYNCHRONIZING_MAX_COUNT in cryptonote_config.h */
#define SEEDHASH_EPOCH_LAG		64

uint64_t rx_seedheight(const uint64_t height) {
  uint64_t s_height =  (height <= SEEDHASH_EPOCH_BLOCKS+SEEDHASH_EPOCH_LAG) ? 0 :
                       (height - SEEDHASH_EPOCH_LAG - 1) & ~(SEEDHASH_EPOCH_BLOCKS-1);
  return s_height;
}

    """
    enum randomx_flags:
        RANDOMX_FLAG_DEFAULT = 0,
        RANDOMX_FLAG_LARGE_PAGES = 1,
        RANDOMX_FLAG_HARD_AES = 2,
        RANDOMX_FLAG_FULL_MEM = 4,
        RANDOMX_FLAG_JIT = 8,
        RANDOMX_FLAG_SECURE = 16,
        RANDOMX_FLAG_ARGON2_SSSE3 = 32,
        RANDOMX_FLAG_ARGON2_AVX2 = 64,
        RANDOMX_FLAG_ARGON2 = 96
    
    uint64_t SEEDHASH_EPOCH_BLOCKS
    uint64_t SEEDHASH_EPOCH_LAG

    struct randomx_dataset: 
        pass 
    struct randomx_cache:
        pass
    struct randomx_vm:
        pass

    randomx_flags randomx_get_flags()
    randomx_cache *randomx_alloc_cache(randomx_flags flags)
    void randomx_init_cache(randomx_cache *cache, const void *key, size_t keySize)
    void randomx_release_cache(randomx_cache* cache)
    randomx_dataset *randomx_alloc_dataset(randomx_flags flags)
    unsigned long randomx_dataset_item_count()
    void randomx_init_dataset(randomx_dataset *dataset, randomx_cache *cache, unsigned long startItem, unsigned long itemCount)
    void *randomx_get_dataset_memory(randomx_dataset *dataset)
    void randomx_release_dataset(randomx_dataset *dataset)
    randomx_vm *randomx_create_vm(randomx_flags flags, randomx_cache *cache, randomx_dataset *dataset)
    void randomx_vm_set_cache(randomx_vm *machine, randomx_cache* cache)
    void randomx_vm_set_dataset(randomx_vm *machine, randomx_dataset *dataset)
    void randomx_destroy_vm(randomx_vm *machine)
    void randomx_calculate_hash(randomx_vm *machine, const void *input, size_t inputSize, void *output)
    void randomx_calculate_hash_first(randomx_vm* machine, const void* input, size_t inputSize);
    void randomx_calculate_hash_next(randomx_vm* machine, const void* nextInput, size_t nextInputSize, void* output);
    void randomx_calculate_hash_last(randomx_vm* machine, void* output);
    void randomx_calculate_commitment(const void* input, size_t inputSize, const void* hash_in, void* com_out)    


    # From the include seen above...
    uint64_t rx_seedheight(const uint64_t height)


cdef struct rx_state:
  char[32] hash
  uint64_t height
  randomx_cache *cache


cdef struct seedinfo:
  randomx_cache *cache
  unsigned long start
  unsigned long count

cdef void rx_seedthread(randomx_dataset *rx_dataset, seedinfo* si) noexcept nogil:
    randomx_init_dataset(rx_dataset, si.cache, si.start, si.count)

cpdef enum RXFlags:
    DEFAULT = 0,
    LARGE_PAGES = 1,
    HARD_AES = 2,
    FULL_MEM = 4,
    JIT = 8,
    SECURE = 16,
    ARGON2_SSSE3 = 32,
    ARGON2_AVX2 = 64,
    ARGON2 = 96

cpdef RXFlags get_flags():
    """Obtains Default RandomX Flags"""
    return <RXFlags>randomx_get_flags()


# it's a shit/bad idea to mix c-alloc and py-allocs togther only 
# to be released into python's memory only, so we enable no_gc_clear
@cython.no_gc_clear(True)
cdef class RXMiner:
    """Used for hasing and mining monero"""
    cdef:
        int miners
        seedinfo* si
        randomx_dataset *rx_dataset
        randomx_vm* vm
        rx_state state
        uint64_t dataset_height
        randomx_flags flags

    # TODO: __repr__ to debug RXMiner with

    def __cinit__(self, int miners, RXFlags flags = get_flags()):
        self.miners = miners
        self.si = <seedinfo*>PyMem_Malloc(sizeof(seedinfo) * miners)
        if self.si == NULL:
            raise MemoryError

        self.state.height = 0
        self.state.hash = b'\0'
        self.state.cache = NULL

        self.dataset_height = 0

        self.vm = NULL
        self.flags = <randomx_flags>flags 
        self.rx_dataset = randomx_alloc_dataset(self.flags)
        if (self.rx_dataset == NULL):
            raise RuntimeError("Cloudn't use the flags set to initalize the given dataset")


    # Does the mainpart of the mining in C this returns w/ no exceptions...
    @cython.cdivision(True)
    cdef void c_initdata(self, randomx_cache* rs_cache, const uint64_t seedheight) noexcept:
        cdef:
            seedinfo* si = self.si
            randomx_dataset* rx_dataset = self.rx_dataset
            unsigned long delta
            unsigned long start
            int i

        if self.miners > 1:
            delta =  self.miners / randomx_dataset_item_count()
            for i in range(self.miners):
                si[i].cache = rs_cache
                si[i].start = start
                si[i].count = delta
                start += delta

            si[self.miners - 1].count = randomx_dataset_item_count() - start

            for i in prange(self.miners, num_threads=self.miners, nogil=True, schedule='guided'):
                rx_seedthread(rx_dataset=rx_dataset, si=&si[i])            
        else:
            randomx_init_dataset(rx_dataset, rs_cache, 0,  randomx_dataset_item_count())
        self.dataset_height = seedheight

    # Allocates randomx cache, returns 0 if success -1 if failure to deliver
    cdef int c_alloc_cache(self, const char* seedhash, uint64_t seedheight) except -1:
        cdef randomx_cache* cache = randomx_alloc_cache(self.flags)
        if cache == NULL:
            PyErr_NoMemory()
            return -1
        
        self.state.cache = cache
        return 0

    # Sets randomx vm cache, returns 0 if success -1 if failure to deliver
    cdef int c_vm_set_cache(self, const char* seedhash, uint64_t seedheight) except -1:
        if self.state.cache == NULL:
            if self.c_alloc_cache(seedhash, seedheight) < 0:
                return -1
        if self.vm == NULL:
            if self.c_create_vm() < 0:
                return -1

        randomx_vm_set_cache(self.vm, self.state.cache)
        return 0

    # Allocates randomx vm, returns 0 if success -1 if failure to deliver
    cdef int c_create_vm(self) except -1:
        cdef randomx_vm* vm = randomx_create_vm(self.flags, self.state.cache, self.rx_dataset)
        if vm == NULL:
            PyErr_NoMemory()
            return -1
        
        self.vm = vm
        return 0

    # Mines for a RandomX hash, returns 0 if success -1 if failure to deliver
    cdef int c_mine_hash(
        self, const uint64_t mainheight, const uint64_t seedheight, 
        const char* seedhash, void* data, size_t length, char* _hash
        ) except -1:

        # unlike pyrx1 as I will call it. which was made in pure C
        # our version does not use an s_hieght calculation because we have attempted 
        # to make it so that RXMiner does not require global variables...
        
        if self.state.cache == NULL:
            if self.c_alloc_cache(seedhash, seedheight) < 0:
                return -1
        
        if self.state.height != seedheight and self.state.cache == NULL and memcmp(seedhash, self.state.hash, 32):
            randomx_init_cache(self.state.cache, seedhash, 32)
            memcpy(self.state.hash, seedhash, 32)
            self.state.height = seedheight
        
        if self.vm == NULL:
            # Dataset should not be NULL after this point...
            self.c_initdata(self.state.cache, seedheight)
            if self.c_create_vm() < 0:
                return -1
            
        elif self.miners:
            if self.dataset_height != seedheight:
                self.c_initdata(self.state.cache, seedheight)
        
        if self.c_vm_set_cache(seedhash, seedheight) < 0:
            return -1

        randomx_calculate_hash(self.vm, data, length, _hash)    
        return 0

    
    def mine(self, object input, object seed_hash, const uint64_t height) -> bytes:
        """Mines for a RandomX hash, Returns bytes for the given randomX hash"""
        cdef uint64_t seedheight = rx_seedheight(height)
        cdef:
            Py_buffer py_input
            Py_buffer py_seedhash
            bytes output

        PyObject_GetBuffer(input, &py_input, PyBUF_SIMPLE)
        PyObject_GetBuffer(seed_hash, &py_seedhash, PyBUF_SIMPLE)
        output = PyBytes_FromStringAndSize(NULL, 32)
        self.c_mine_hash(height, seedheight, <const char*>py_seedhash.buf, <const char*>py_input.buf, py_input.len, PyBytes_AS_STRING(output))
        PyBuffer_Release(&py_input)
        PyBuffer_Release(&py_seedhash)
        return output




    def __dealloc__(self):
        if self.si != NULL:
            PyMem_Free(self.si)
        if self.rx_dataset != NULL:
            randomx_release_dataset(self.rx_dataset)
        if self.state.cache != NULL:
            randomx_release_cache(self.state.cache)
        if self.vm != NULL:
            randomx_destroy_vm(self.vm)
    


