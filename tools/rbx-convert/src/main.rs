//! Convert a binary Roblox place or model into the XML form.
//!
//! Why this exists
//! ---------------
//!
//! Half the licensed projects we are harvesting ship as binary `.rbxl`, and the
//! Python harvester reads XML only. Every one of those places holds the things
//! a library actually wants -- rigs, tools, animations, HUDs -- and the note in
//! `forge/cli/kit.py` said to open them in Studio by hand, "a person's job once
//! rather than a parser to maintain for ever".
//!
//! That was the right call about writing a parser and the wrong conclusion,
//! because there is a third option: `rbx-dom` already parses both formats, and
//! rojo already depends on it. Thirty lines of glue turns a manual step nobody
//! will repeat into a command the harvester can call on every file it meets.
//!
//! Rojo itself cannot be used for this: it refuses a model file with more than
//! one top-level instance, and a *place* is by definition many -- one per
//! service. That refusal is correct for rojo and simply not applicable here.

use std::env;
use std::fs::File;
use std::io::{BufReader, BufWriter};
use std::process::ExitCode;

fn main() -> ExitCode {
    let args: Vec<String> = env::args().collect();
    if args.len() != 3 {
        eprintln!("usage: rbx-convert <input.rbxl|.rbxm> <output.rbxlx|.rbxmx>");
        return ExitCode::from(2);
    }

    let input = BufReader::new(match File::open(&args[1]) {
        Ok(file) => file,
        Err(error) => {
            eprintln!("cannot read {}: {error}", args[1]);
            return ExitCode::from(1);
        }
    });

    let dom = match rbx_binary::from_reader(input) {
        Ok(dom) => dom,
        Err(error) => {
            eprintln!("{} is not a readable binary Roblox file: {error}", args[1]);
            return ExitCode::from(1);
        }
    };

    // Every root, not just the first. A place's roots are its services, and
    // dropping all but one is how you lose StarterGui -- which is where the
    // HUDs live, and HUDs are a stated reason this tool was asked for.
    let roots: Vec<_> = dom.root().children().to_vec();

    let output = BufWriter::new(match File::create(&args[2]) {
        Ok(file) => file,
        Err(error) => {
            eprintln!("cannot write {}: {error}", args[2]);
            return ExitCode::from(1);
        }
    });

    match rbx_xml::to_writer_default(output, &dom, &roots) {
        Ok(()) => {
            println!("{} -> {} ({} roots)", args[1], args[2], roots.len());
            ExitCode::SUCCESS
        }
        Err(error) => {
            eprintln!("cannot serialise to XML: {error}");
            ExitCode::from(1)
        }
    }
}
