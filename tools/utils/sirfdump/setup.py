#!/usr/bin/env python

DESCRIPTION = 'Utility to dump SirfBin Data in a readable format'

import os, re
def get_version():
    VERSIONFILE = os.path.join('sirfdump', '__init__.py')
    initfile_lines = open(VERSIONFILE, 'rt').readlines()
    VSRE = r"^__version__ = ['\"]([^'\"]*)['\"]"
    for line in initfile_lines:
        mo = re.search(VSRE, line, re.M)
        if mo:
            return mo.group(1)
    raise RuntimeError('Unable to find version string in %s.' % (VERSIONFILE,))

try:
    from setuptools import setup
except ImportError:
    from distutils.core import setup

setup(
    name             = 'sirfdump',
    version          = get_version(),
    url              = 'https://github.com/MamMark/mm/tools/utils/sirfdump',
    author           = 'Eric B. Decker',
    author_email     = 'cire831@gmail.com',
#    license_file     = 'LICENCE.txt',
    license          = 'GPL3',
    packages         = ['sirfdump'],
    install_requires = [ 'tagcore' ],
    entry_points     = {
        'console_scripts': ['sirfdump=sirfdump.__main__:main'],
    }
)
