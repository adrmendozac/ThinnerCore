import React, {useEffect, useState} from 'react';
import {Text, useStdout} from 'ink';

const letters = {
  t: ['████████╗', '╚══██╔══╝', '   ██║   ', '   ██║   ', '   ██║   ', '   ╚═╝   '],
  h: ['██╗  ██╗', '██║  ██║', '███████║', '██╔══██║', '██║  ██║', '╚═╝  ╚═╝'],
  i: ['██╗', '██║', '██║', '██║', '██║', '╚═╝'],
  n: ['███╗   ██╗', '████╗  ██║', '██╔██╗ ██║', '██║╚██╗██║', '██║ ╚████║', '╚═╝  ╚═══╝'],
  e: ['███████╗', '██╔════╝', '█████╗  ', '██╔══╝  ', '███████╗', '╚══════╝'],
  r: ['██████╗ ', '██╔══██╗', '██████╔╝', '██╔══██╗', '██║  ██║', '╚═╝  ╚═╝'],
  c: [' ██████╗', '██╔════╝', '██║     ', '██║     ', '╚██████╗', ' ╚═════╝'],
  o: [' ██████╗ ', '██╔═══██╗', '██║   ██║', '██║   ██║', '╚██████╔╝', ' ╚═════╝ '],
};
const word = value => Array.from({length: 6}, (_, row) =>
  [...value].map(letter => letters[letter][row]).join(''));
const full = word('thinnercore');
const stacked = [...word('thinner'), '', ...word('core')];
const fits = (rows, width) => rows.every(row => row.length <= width);

export function Banner({color = true}) {
  const {stdout} = useStdout();
  const [width, setWidth] = useState((stdout.columns ?? 80) - 8);
  useEffect(() => {
    const resize = () => setWidth((stdout.columns ?? 80) - 8);
    stdout.on('resize', resize);
    return () => stdout.off('resize', resize);
  }, [stdout]);
  return React.createElement(Text, {bold: true, ...(color ? {color: 'cyan'} : {})},
    fits(full, width) ? full.join('\n') : fits(stacked, width) ? stacked.join('\n') : 'thinnercore');
}
