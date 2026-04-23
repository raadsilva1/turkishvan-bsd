#!/bin/tcsh -f

# FreeBSD 16 dependency resolution + build script for tkvnbsd
# Usage:
#   tcsh ./build_tkvnbsd.tcsh [path/to/tkvnbsd.zig] [output-binary]
# Default source:  ./tkvnbsd.zig
# Default output:  ./tkvnbsd

set script_name = "$0:t"
set src = "./tkvnbsd.zig"
set out = "./tkvnbsd"

if ( $#argv >= 1 ) then
    set src = "$argv[1]"
endif
if ( $#argv >= 2 ) then
    set out = "$argv[2]"
endif

if ( ! -f "$src" ) then
    echo "$script_name: source not found: $src"
    exit 1
endif

set need_root = 0
if ( `id -u` != 0 ) then
    set need_root = 1
endif

set elevate = ""
if ( $need_root ) then
    if ( -x /usr/local/bin/doas ) then
        set elevate = "/usr/local/bin/doas"
    else if ( -x /usr/local/bin/sudo ) then
        set elevate = "/usr/local/bin/sudo"
    endif
endif

set os_name = `uname -s`
set os_rel = `uname -r`
set os_major = `echo "$os_rel" | sed -E 's/^([0-9]+).*/\1/'`

if ( "$os_name" != "FreeBSD" ) then
    echo "$script_name: this script only supports FreeBSD"
    exit 1
endif

if ( "$os_major" != "16" ) then
    echo "$script_name: this project targets FreeBSD 16 only (detected $os_rel)"
    exit 1
endif

if ( ! -x /usr/sbin/pkg && ! -x /usr/local/sbin/pkg ) then
    echo "$script_name: pkg is not installed"
    echo "Install pkg first, then rerun this script."
    exit 1
endif

if ( ! -f /usr/local/sbin/pkg ) then
    # Some systems only place pkg in /usr/local/sbin after bootstrap.
    if ( $need_root && "$elevate" == "" ) then
        echo "$script_name: package bootstrap may be required, but no doas/sudo was found."
        echo "Run as root or install doas/sudo."
        exit 1
    endif
    echo "==> Bootstrapping pkg"
    if ( $need_root ) then
        env ASSUME_ALWAYS_YES=yes $elevate /usr/sbin/pkg bootstrap
    else
        env ASSUME_ALWAYS_YES=yes /usr/sbin/pkg bootstrap
    endif
    if ( $status != 0 ) then
        echo "$script_name: pkg bootstrap failed"
        exit 1
    endif
endif

set pkg_cmd = "/usr/local/sbin/pkg"
if ( ! -x "$pkg_cmd" ) then
    set pkg_cmd = "/usr/sbin/pkg"
endif

set missing = ()
foreach p ( zig ncurses )
    $pkg_cmd info -e "$p" >& /dev/null
    if ( $status != 0 ) then
        set missing = ( $missing "$p" )
    endif
end

if ( $#missing > 0 ) then
    if ( $need_root && "$elevate" == "" ) then
        echo "$script_name: missing packages: $missing"
        echo "Run as root or install doas/sudo so the script can resolve dependencies."
        exit 1
    endif

    echo "==> Installing dependencies: $missing"
    if ( $need_root ) then
        env ASSUME_ALWAYS_YES=yes $elevate $pkg_cmd install -y $missing
    else
        env ASSUME_ALWAYS_YES=yes $pkg_cmd install -y $missing
    endif
    if ( $status != 0 ) then
        echo "$script_name: dependency installation failed"
        exit 1
    endif
endif

set zig_bin = ""
if ( -x /usr/local/bin/zig ) then
    set zig_bin = "/usr/local/bin/zig"
else
    set zig_bin = `which zig 2> /dev/null`
endif

if ( "$zig_bin" == "" ) then
    echo "$script_name: zig not found after dependency resolution"
    exit 1
endif

set incflags = ()
set libflags = ()
set ncurses_lib = ""

if ( -f /usr/local/include/ncurses.h ) then
    set incflags = ( -I /usr/local/include )
endif

if ( -f /usr/local/lib/libncurses.so || -f /usr/local/lib/libncurses.a ) then
    set libflags = ( -L /usr/local/lib )
    set ncurses_lib = "-lncurses"
else if ( -f /usr/local/lib/libncursesw.so || -f /usr/local/lib/libncursesw.a ) then
    set libflags = ( -L /usr/local/lib )
    set ncurses_lib = "-lncursesw"
else if ( -f /lib/libncurses.so || -f /usr/lib/libncurses.so ) then
    set ncurses_lib = "-lncurses"
else if ( -f /lib/libncursesw.so || -f /usr/lib/libncursesw.so ) then
    set ncurses_lib = "-lncursesw"
endif

if ( "$ncurses_lib" == "" ) then
    echo "$script_name: unable to locate an ncurses library"
    exit 1
endif

set out_dir = "$out:h"
if ( "$out_dir" == "" ) then
    set out_dir = "."
endif
if ( ! -d "$out_dir" ) then
    mkdir -p "$out_dir"
    if ( $status != 0 ) then
        echo "$script_name: failed to create output directory: $out_dir"
        exit 1
    endif
endif

set build_cmd = ( "$zig_bin" build-exe "$src" -O ReleaseSafe -femit-bin="$out" -lc $incflags $libflags $ncurses_lib )

echo "==> Source:      $src"
echo "==> Output:      $out"
echo "==> Zig:         $zig_bin"
echo "==> OS:          $os_name $os_rel"
echo "==> ncurses lib: $ncurses_lib"
echo -n "==> Build command:"
foreach arg ( $build_cmd )
    echo -n " $arg"
end
echo ""

$build_cmd
if ( $status != 0 ) then
    echo "$script_name: build failed"
    exit 1
endif

chmod 755 "$out"
if ( $status != 0 ) then
    echo "$script_name: build succeeded, but chmod failed for $out"
    exit 1
endif

echo "==> Build complete: $out"
file "$out"
exit 0
