use tether_terminal::{Dimensions, Frame, FrameStamp};
use ts_rs::TS;

fn main() {
    for declaration in [Dimensions::decl(), FrameStamp::decl(), Frame::decl()] {
        println!("export {declaration}");
    }
}
