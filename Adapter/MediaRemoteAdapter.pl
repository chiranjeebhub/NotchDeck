# Loads MediaRemoteAdapter.dylib into perl and runs its stream function.
# Usage: /usr/bin/perl MediaRemoteAdapter.pl /path/to/MediaRemoteAdapter.dylib
use strict;
use warnings;
use DynaLoader;

my $path = shift or die "usage: $0 <dylib>\n";
my $handle = DynaLoader::dl_load_file($path, 0) or die DynaLoader::dl_error();
my $symbol = DynaLoader::dl_find_symbol($handle, "notch_adapter_stream") or die DynaLoader::dl_error();
DynaLoader::dl_install_xsub("main::notch_adapter_stream", $symbol);
main::notch_adapter_stream();
