export type Dimensions = { columns: number, rows: number, };
export type FrameStamp = { runtime: string, revision: number, };
export type Frame = { stamp: FrameStamp, dimensions: Dimensions, painting: string, history_rows: number, history_bytes: number, rejected_osc: number, rejected_marks: number, };
