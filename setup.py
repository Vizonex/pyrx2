from setuptools import setup, Extension
from setuptools.command.build_ext import build_ext

import pathlib
import sys, os
import subprocess



ROOT = pathlib.Path(__file__).parent
RXV = ROOT / "RandomX"
SRC = RXV / "src"

CFLAGS = ["-O2"]
OBJ_PATH = ROOT / "obj"

# COPIED FROM Distutils...

def _find_exe(exe, paths=None):
    """Return path to an MSVC executable program.

    Tries to find the program in several places: first, one of the
    MSVC program search paths from the registry; next, the directories
    in the PATH environment variable.  If any of those work, return an
    absolute path that is known to exist.  If none of them work, just
    return the original program name, 'exe'.
    """
    if not paths:
        paths = os.getenv('path').split(os.pathsep)
    for p in paths:
        fn = os.path.join(os.path.abspath(p), exe)
        if os.path.isfile(fn):
            return fn
    return exe


# This currently only works on Windows
# TODO: Seperate build_ext for linux and APPLE

class pyrx2_build_ext(build_ext):
    def src(self, file: str):
        """Adds a source OR Include file to the list"""
        return str(SRC / file)

    def find_ml_exe(self):
        # We need to get the assembly compiler or we're screwed
        self.compiler.initialize()
        paths = self.compiler._paths.split(os.pathsep)
        if sys.maxsize > 2 ** 32:
            self.ml = _find_exe("ml64.exe", paths)
        else:
            self.ml = _find_exe("ml.exe", paths)


    def build_extensions(self):
        self.find_ml_exe()
        print(self.ml)

        subprocess.check_output(
            [
                "powershell",
                "-ExecutionPolicy",
                "Bypass",
                "-File",
                ".\\h2inc.ps1",
                ".\\RandomX\\src\\configuration.h",
                "&gt;",
                "RandomX\\src\\asm\\configuration.asm",
                "SET",
                "ERRORLEVEL",
                "=",
                "0",
            ]
        )

        if not OBJ_PATH.exists():
            OBJ_PATH.mkdir()
        
        print(subprocess.check_output(
            [
                self.ml,
                "/Fo",
                str(OBJ_PATH / "jit_compiler_x86_static.obj"),
                "/c",
                self.src("jit_compiler_x86_static.asm"),
                "/nologo"
            ]
        ))

        
        
        assert SRC.exists(), "source files for RandomX must exist"
        mod: Extension = self.distribution.ext_modules[0]
        jit_obj = str(OBJ_PATH / "jit_compiler_x86_static.obj")
        # self.compiler.src_extensions.append(jit_obj)
        
        mod.sources.extend([
            self.src("allocator.cpp"),
            self.src("argon2_ref.c"),
            self.src("argon2_avx2.c"),
            self.src("argon2_core.c"),
            self.src("argon2_ssse3.c"),
            self.src("assembly_generator_x86.cpp"),
            self.src("blake2_generator.cpp"),
            self.src(pathlib.Path("blake2") / "blake2b.c"),
            self.src("bytecode_machine.cpp"),
            self.src("cpu.cpp"),
            self.src("vm_compiled_light.cpp"),
            self.src("vm_compiled.cpp"),
            self.src("dataset.cpp"),
            self.src("aes_hash.cpp"),
            self.src("instruction.cpp"),
            self.src("instructions_portable.cpp"),
            self.src("vm_interpreted_light.cpp"),
            self.src("vm_interpreted.cpp"),
            self.src("jit_compiler_x86.cpp"),
            self.src("randomx.cpp"),
            self.src("superscalar.cpp"),
            self.src("reciprocal.c"),
            self.src("soft_aes.cpp"),
            self.src("virtual_machine.cpp"),
            self.src("virtual_memory.c"),
            ]
        )
        
        # print(mod.sources)
        mod.include_dirs.extend([
            str(SRC),
            str(SRC / "blake2")
        ])
        self.compiler.add_link_object(jit_obj)
        super().build_extensions()
        
def main():
    VERSION = "0.0.1"

    from Cython.Build import cythonize
    # from Cython.Compiler.Main import default_options

    ext = cythonize(
        [
            Extension(
                "pyrx2._pyrx2",
                sources=["pyrx2/_pyrx2.pyx"],
                include_dirs=["RandomX/src"],
                extra_link_args=["advapi32.lib", "user32.lib", str(OBJ_PATH / "jit_compiler_x86_static.obj")],
            )
        ]
    )
    # setup_requires = []
    setup(
        version=VERSION,
        cmdclass={
            # 'sdist': uvloop_sdist,
            "build_ext": pyrx2_build_ext
        },
        ext_modules=ext,
        # define_macros=[
        #     ("march", "native"),
        # ]
    )
    # Delete Temporary Object file when were done with it.
    os.remove(OBJ_PATH / "jit_compiler_x86_static.obj")
    os.removedirs(OBJ_PATH)

if __name__ == "__main__":
    main()
