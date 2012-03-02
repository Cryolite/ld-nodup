#! /usr/bin/ruby

require 'tempfile'

# Check '--nodup' option and extract the output filename.
is_nodup = false
expect_filename = false
output_filename = nil
ARGV.each {|v|
  if v == '--nodup' then
    is_nodup = true
    next
  end
  if v == '-o' then
    expect_filename = true
    next
  end
  if expect_filename then
    output_filename = v
    expect_filename = false
    next
  end
  if /^--output=(.*)$/ =~ v then
    output_filename = $1
    next
  end
}

# Prepare the link command and options.
link_command = nil
if is_nodup then
  link_command = '/usr/bin/gold --trace --detect-odr-violations'
else
  link_command = '/usr/bin/ld'
end
ARGV.each {|v|
  if v == '--nodup' then
    next
  end
  link_command << ' "' << v << '"'
}

# Execute the link command.
# Outputs by `--trace' option will be written to the stderr.
ld_err = nil
ld_out = nil
ld_status = nil
Tempfile.open('tmp') {|tmp_file|
  ld_out = `#{link_command} 2>#{tmp_file.path}`
  ld_status = $?
  ld_err = tmp_file.read
}
if !is_nodup || ld_status != 0 then
  # Exit immediately if '--nodup' is not specified or the link failed.
  print ld_out
  STDERR.print ld_err
  exit ld_status
end
# Print normal outputs from the linker.
print ld_out

def scanLinkerOutputLine line
  line.chomp!

  if /^-l(.*) \((.*)\)$/ =~ line then
    # The path to a library file following the corresponding `-l' option,
    # which `ld' could output.
    return [$1, $2]
  end

  if /^\((.*)\).*$/ =~ line then
    # The path to an archive file followed by a contained object file name,
    # which `ld' could output.
    return [nil, $1]
  end

  if /^(.*) \(.*\)$/ =~ line then
    # The path to a library file (followed by a weird path???),
    # which `ld' could output.
    return [nil, $1]
  end

  if /^(.*)\(.*\)$/ =~ line then
    # The path to an archive file followed by a contained object file name,
    # which `gold' could output.
    return [nil, $1]
  end

  if /ld: mode/ =~ line then
    # `ld --trace' outputs a non-informative string in the first line
    # such as `/usr/bin/ld: mode elf_x86_64'. Skip.
    return [nil, nil]
  end

  if File.exist?(line) then
    # The line just contains the path to an object or library file,
    # which `ld' or `gold' could output.
    return [nil, line]
  end

  # Another kind of line in the stderr from the linker.
  STDERR.puts line
  return [nil, nil]
end

# List containing the paths of already scanned files.
libs = Hash.new

# List containing the already defined symbols.
symbols = Hash.new

# List containing the symbols of no interest.
special_symbols = {'_init' => nil, '_fini' => nil}

# Status code to be returned from this script.
status = 0

ld_err.each {|ld_line|
  ld_line.chomp!

  search_opt, lib_path = scanLinkerOutputLine(ld_line)
  if !lib_path then
    # Skip the line of no interest.
    next
  end
  # Normalize the path string.
  lib_path = File.expand_path(lib_path)

  # Check the file existence.
  if !File.exist?(lib_path) then
    STDERR.puts "ERROR: cannot find the file `#{lib_path}'"
    if search_opt then
      STDERR.puts "       searched by `-l#{search_opt}'"
    end
    exit 1
  end

  # `ld --trace' and `gold --trace' could
  # output the path to a library file multiple times, e.g.,
  # each of which is for an objct file contained in an archive file.
  # So, skip the second and subsequent outputs of the same path.
  if libs.has_key?(lib_path) then
    next
  end
  libs.store(lib_path, nil)

  # Execute the `nm'.
  nm_out = `nm "#{lib_path}" 2>&1`
  nm_status = $?
  if nm_status != 0 then
    STDERR.puts "ERROR: `nm' on `#{lib_path}' failed"
    if search_opt then
      STDERR.puts "       searched by `-l#{search_opt}'"
    end
    exit nm_status
  end

  if /no symbols/ =~ nm_out then
    # Skip the file that does not contain any symbol.
    next
  end

  nm_out.each {|nm_line|
    nm_line.chomp!
    if /:$/ =~ nm_line then
      # Skip the first line, which is of no interest.
      next
    end

    if /^[[:xdigit:]]+ ([ABbCDdGgiNpRrSsTtUuVvWw\-\?]) (.*)/ =~ nm_line
      kind = $1
      symbol = $2

      if special_symbols.has_key?(symbol) then
        # Skip a special symbol, in which we don't have any interest.
        next
      end

      if kind == 'T' then
        # A global symbol in the text (code) section.
        if symbols.has_key?(symbol) then
          # Multiple definitions found.
          first_path, first_opt = symbols.fetch(symbol)
          STDERR.puts "ERROR: #{lib_path}: #{symbol}: multiple definitions in the text section"
          if search_opt then
            STDERR.puts "         searched by `-l#{search_opt}'"
          end
          STDERR.puts "ERROR: #{first_path}: first defined here"
          if first_opt then
            STDERR.puts "         searched by `-l#{first_opt}'"
          end
          # Set the error status code and go to the next symbol.
          status = 1
          next
        end
        # First definition.
        symbols.store(symbol, [lib_path, search_opt])
      end
    end
  }
}

if status != 0 then
  File.delete(output_filename)
end
exit status
