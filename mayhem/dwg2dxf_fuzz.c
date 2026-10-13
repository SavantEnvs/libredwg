/* libFuzzer harness: decode a DWG from memory and export it as DXF, the dwg2dxf code path
   (decode -> out_dxf -> get_next_owned_block_entity -> dwg_next_entity). */
#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "common.h"
#include <dwg.h>
#include "decode.h"
#include "bits.h"
#include "out_dxf.h"

int
LLVMFuzzerTestOneInput (const unsigned char *data, size_t size)
{
  Dwg_Data dwg;
  Bit_Chain dat;
  Bit_Chain out_dat;
  char *outbuf = NULL;
  size_t outlen = 0;
  unsigned char *copy;
  int error;

  if (size < 6 || size > 10 * 1024 * 1024)
    return -1;
  if (data[0] != 'A' || data[1] != 'C')
    return -1;

  copy = (unsigned char *)malloc (size);
  if (!copy)
    return 0;
  memcpy (copy, data, size);
  memset (&dat, 0, sizeof (dat));
  memset (&dwg, 0, sizeof (dwg));
  dat.chain = copy;
  dat.size = size;

  error = dwg_decode (&dat, &dwg);
  if (error >= DWG_ERR_CRITICAL)
    {
      dwg_free (&dwg);
      free (copy);
      return 0;
    }

  memset (&out_dat, 0, sizeof (out_dat));
  out_dat.version = dwg.header.version;
  out_dat.from_version = dwg.header.from_version;
  out_dat.fh = open_memstream (&outbuf, &outlen);
  if (out_dat.fh)
    {
      dwg_write_dxf (&out_dat, &dwg);
      fclose (out_dat.fh);
      free (outbuf);
    }
  dwg_free (&dwg);
  free (copy);
  return 0;
}
