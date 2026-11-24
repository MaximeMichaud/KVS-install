"""Create a minimal install archive for manager tests."""
import sys
import zipfile

with zipfile.ZipFile(sys.argv[1], "w") as archive:
    archive.writestr("admin/include/setup.php", "<?php\n$config['tables_prefix']='ktvs_';\n")
