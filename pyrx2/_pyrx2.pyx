# cython: language_level = 3
cimport cython
from cython.parallel import prange # type: ignore

from cpython.buffer cimport PyBUF_SIMPLE, PyObject_GetBuffer, PyBuffer_Release
from cpython.bytes cimport PyBytes_FromStringAndSize, PyBytes_AS_STRING
from cpython.exc cimport PyErr_NoMemory
from cpython.mem cimport PyMem_Malloc, PyMem_Free
from libc.stdint cimport uint64_t
from libc.string cimport memcpy, memcmp



cdef extern from "randomx.h" nogil:
    """
#define SEEDHASH_EPOCH_BLOCKS	2048	/* Must be same as BLOCKS_SYNCHRONIZING_MAX_COUNT in cryptonote_config.h */
#define SEEDHASH_EPOCH_LAG		64

uint64_t rx_seedheight(const uint64_t height) {
  uint64_t s_height =  (height <= SEEDHASH_EPOCH_BLOCKS+SEEDHASH_EPOCH_LAG) ? 0 :
                       (height - SEEDHASH_EPOCH_LAG - 1) & ~(SEEDHASH_EPOCH_BLOCKS-1);
  return s_height;
}

static const char DEFAULT_HASH[32] = {0};

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
    const char* DEFAULT_HASH


cdef struct seedinfo:
    randomx_cache *cache
    unsigned long start
    unsigned long count

cdef void rx_seedthread(randomx_dataset* rx_dataset, seedinfo* si) noexcept nogil:
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


# Went Object Oriented to prevent the possibility of unwanted spaghetti-code

@cython.no_gc_clear
cdef class Cache:
    cdef:
        randomx_cache* cache
    
    def __cinit__(self, RXFlags flags):
        self.cache = randomx_alloc_cache(<randomx_flags>flags)
        if self.cache == NULL:
            raise MemoryError()
        
    cdef inline void c_initialize(self, const void* key, size_t keySize):
        randomx_init_cache(self.cache, key, keySize)

    def initialize(self, object key):
        cdef Py_buffer view
        PyObject_GetBuffer(key, &view, PyBUF_SIMPLE)
        self.c_initialize(view.buf, <size_t>view.len)
        PyBuffer_Release(&view)


    def __dealloc__(self):
        if self.cache != NULL:
            randomx_release_cache(self.cache)
        


@cython.no_gc_clear
cdef class Dataset:
    cdef:
        randomx_dataset* dataset

    def __cinit__(self, RXFlags flags) -> None:
        self.dataset = randomx_alloc_dataset(<randomx_flags>flags)
        if self.dataset == NULL:
            raise MemoryError

    def __dealloc__(self):
        if self.dataset != NULL:
            randomx_release_dataset(self.dataset)

    
    

    cpdef void initalize_dataset(self, Cache cache):
        """Does a single init_dataset without threads"""
        randomx_init_dataset(self.dataset, cache.cache, 0, randomx_dataset_item_count())
    
    @cython.cdivision(True)
    cdef void initalize_dataset_with_threads(self, Cache cache, uint64_t seed_height, seedinfo*si, size_t threads):
        cdef:
            size_t i
            unsigned long delta = randomx_dataset_item_count() / threads
            unsigned long start = 0

        for i in range(threads - 1):
            si[i].cache = cache.cache
            si[i].start = start
            si[i].count = delta
            start += delta

        si[threads - 1].cache = cache.cache 
        si[threads - 1].start = start
        si[threads - 1].count = randomx_dataset_item_count() - start
       
        for i in prange(threads, nogil=True):
            randomx_init_dataset(self.dataset, si[i].cache, si[i].start, si[i].count)
        




@cython.no_gc_clear
cdef class VirtualMachine:
    cdef:
        randomx_vm* vm
        Cache cache
        Dataset dataset
    
    def __cinit__(self, RXFlags flags, Cache cache, Dataset dataset):
        self.vm = randomx_create_vm(<randomx_flags>flags, cache.cache, dataset.dataset)
        if self.vm == NULL:
            raise MemoryError
        
        self.set_cache(cache)
        self.set_dataset(dataset)

    cpdef void set_cache(self, Cache cache):
        randomx_vm_set_cache(self.vm, cache.cache)
        self.cache = cache
    
    cpdef void set_dataset(self, Dataset dataset):
        randomx_vm_set_dataset(self.vm, dataset.dataset)
        self.dataset = dataset
    
    def __dealloc__(self):
        if self.vm != NULL:
            randomx_destroy_vm(self.vm)


    cdef bytes c_calculate_hash(self,  const void *input, size_t inputSize):
        cdef bytes output = PyBytes_FromStringAndSize(NULL, 32)
        randomx_calculate_hash(self.vm, input, inputSize, <void*>PyBytes_AS_STRING(output))
        return output



@cython.no_gc_clear
cdef class RXMiner:
    cdef:
        VirtualMachine vm
        seedinfo* ptr
        uint64_t rs_height
        char[32] rs_hash
        size_t threads

    def __cinit__(self, RXFlags flags, size_t threads):
        self.vm = VirtualMachine(flags, Cache.__new__(Cache, flags), Dataset.__new__(Dataset, flags))
        self.ptr = <seedinfo*>PyMem_Malloc(sizeof(seedinfo) * threads)
        if self.ptr == NULL:
            raise MemoryError
        
        self.rs_height = 0
        self.threads = threads

    
    def mine(self, object input, object seedhash, uint64_t height):
        cdef:
            uint64_t seed_height = rx_seedheight(height)
            Py_buffer seed_view
            Py_buffer input_view
            object out
        
        PyObject_GetBuffer(seedhash, &seed_view, PyBUF_SIMPLE)
        PyObject_GetBuffer(input, &input_view, PyBUF_SIMPLE)

        if self.rs_height != seed_height or memcmp(seed_view.buf, <void*>self.rs_hash, 32):
            self.vm.cache.c_initialize(seed_view.buf, 32)
            self.rs_height = seed_height
            memcpy(<void*>self.rs_hash, seed_view.buf, 32)

        self.vm.dataset.initalize_dataset_with_threads(self.vm.cache, seed_height, self.ptr, self.threads)
        out = self.vm.c_calculate_hash(input_view.buf, <size_t>input_view.len)
        
        PyBuffer_Release(&seed_view)
        PyBuffer_Release(&input_view)
        return out





    def __dealloc__(self):
        if self.ptr != NULL:
            PyMem_Free(self.ptr)

