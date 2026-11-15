from __future__ import annotations
import csv, html, json, zipfile
from pathlib import Path
from typing import Any
from docx import Document
from docx.shared import Inches
from docx.enum.table import WD_TABLE_ALIGNMENT, WD_CELL_VERTICAL_ALIGNMENT
from docx.enum.text import WD_ALIGN_PARAGRAPH
from openpyxl import Workbook
from openpyxl.styles import Alignment, Border, Font, PatternFill, Side
from subtitle_utils import ass_time, collect_word_items, srt_time, vtt_time

def rows_for(segments):
    rows = []
    for i, item in enumerate(segments, 1):
        start, end = float(item.get("start", 0)), float(item.get("end", 0))
        rows.append({"index": i, "start": start, "end": end, "duration": max(0, end-start), "text": str(item.get("text", "")).strip(), "avg_logprob": item.get("avg_logprob"), "no_speech_prob": item.get("no_speech_prob")})
    return rows

def write_text(path, value, bom=False):
    path.write_text(("\ufeff" if bom else "") + value, encoding="utf-8")

def make_sbv(segments, target):
    entries=[]
    for x in segments:
        text=str(x.get("text","")).strip()
        if text: entries.append(f"{vtt_time(float(x['start']))},{vtt_time(float(x['end']))}\n{text}")
    write_text(target, "\n\n".join(entries)+("\n" if entries else ""), True)

def make_ssa(segments, target):
    lines=["[Script Info]","Title: AI Auto Subtitle Creator Studio","ScriptType: v4.00","WrapStyle: 2","","[V4 Styles]","Format: Name, Fontname, Fontsize, PrimaryColour, SecondaryColour, TertiaryColour, BackColour, Bold, Italic, BorderStyle, Outline, Shadow, Alignment, MarginL, MarginR, MarginV, AlphaLevel, Encoding","Style: Default,Arial,22,&H00FFFFFF,&H0000FFFF,&H00000000,&H00000000,0,0,1,2,0,2,30,30,30,0,1","","[Events]","Format: Marked, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text"]
    for x in segments:
        text=html.escape(str(x.get("text","")).strip())
        if text: lines.append(f"Dialogue: Marked=0,{ass_time(float(x['start']))},{ass_time(float(x['end']))},Default,,0,0,0,,{text}")
    write_text(target,"\n".join(lines)+"\n")

def make_csv_tsv(segments, target, delimiter):
    with target.open("w",encoding="utf-8-sig",newline="") as f:
        w=csv.writer(f,delimiter=delimiter)
        w.writerow(["No.","Start (seconds)","End (seconds)","Duration (seconds)","Caption Text","Average Log Probability","No Speech Probability"])
        for r in rows_for(segments):
            w.writerow([r["index"],r["start"],r["end"],r["duration"],r["text"],r["avg_logprob"],r["no_speech_prob"]])

def make_timecoded_txt(segments,target):
    lines=[f"[{srt_time(float(x['start']))[:-4]} - {srt_time(float(x['end']))[:-4]}] {str(x.get('text','')).strip()}" for x in segments if str(x.get("text","")).strip()]
    write_text(target,"\n".join(lines)+("\n" if lines else ""),True)

def make_markdown(segments,target,language):
    lines=["# Transcript","",f"- Detected language: {language}",f"- Caption segments: {len(segments)}","","| # | Start | End | Caption |","|---:|---:|---:|---|"]
    for r in rows_for(segments):
        text=r["text"].replace("|",r"\|").replace("\n"," ")
        lines.append(f"| {r['index']} | {srt_time(r['start'])} | {srt_time(r['end'])} | {text} |")
    write_text(target,"\n".join(lines)+"\n")

def make_html(segments,target,language):
    body=[]
    for r in rows_for(segments):
        body.append("<tr><td>"+str(r["index"])+"</td><td>"+srt_time(r["start"])+"</td><td>"+srt_time(r["end"])+"</td><td>"+html.escape(r["text"])+"</td></tr>")
    document=("<!doctype html><html><head><meta charset='utf-8'><meta name='viewport' content='width=device-width,initial-scale=1'>"
              "<title>Transcript</title><style>body{font:16px Arial,sans-serif;background:#f4f6fb;padding:24px;color:#192033}"
              "main{max-width:1100px;margin:auto;background:white;padding:24px;border-radius:14px}table{width:100%;border-collapse:collapse}"
              "td,th{padding:10px;border-bottom:1px solid #ddd;text-align:left}th{background:#252a45;color:white}</style></head><body><main>"
              "<h1>Video Transcript</h1><p>Detected language: "+html.escape(language)+"</p><table><tr><th>#</th><th>Start</th><th>End</th><th>Caption</th></tr>"
              +"".join(body)+"</table></main></body></html>")
    write_text(target,document)

def make_xlsx(segments,target,insights,language):
    wb=Workbook()
    ws=wb.active; ws.title="Captions"
    ws.append(["No.","Start (seconds)","End (seconds)","Duration (seconds)","Caption Text","Average Log Probability","No Speech Probability"])
    for r in rows_for(segments):
        ws.append([r["index"],r["start"],r["end"],r["duration"],r["text"],r["avg_logprob"],r["no_speech_prob"]])
    word_ws=wb.create_sheet("Word Timing")
    word_ws.append(["No.","Word","Start (seconds)","End (seconds)","Duration (seconds)","Alignment Probability"])
    objects=[]
    for x in segments:
        class Segment: pass
        seg=Segment(); seg.text=x.get("text",""); seg.start=float(x.get("start",0)); seg.end=float(x.get("end",0))
        seg.words=[]
        for word in x.get("words",[]):
            class Word: pass
            obj=Word(); obj.word=word.get("text",""); obj.start=float(word.get("start",0)); obj.end=float(word.get("end",0)); obj.probability=word.get("probability")
            seg.words.append(obj)
        objects.append(seg)
    for i,w in enumerate(collect_word_items(objects),1):
        word_ws.append([i,w["text"],w["start"],w["end"],max(0,w["end"]-w["start"]),w.get("probability")])
    pulse=wb.create_sheet("Creator Pulse"); pulse.append(["Metric","Value"]); pulse.append(["Detected language",language])
    for key,label in [("word_count","Word count"),("duration_seconds","Duration (seconds)"),("speaking_rate_wpm","Speaking rate (WPM)"),("pause_count_over_1_2s","Long pauses"),("word_alignment_probability_mean","Mean alignment probability")]:
        pulse.append([label,(insights or {}).get(key,"")])
    for key,label in [("filler_word_counts","Filler word counts"),("long_pauses","Long pauses detail"),("low_alignment_probability_words","Review words"),("hook_moment_suggestions","Hook suggestions")]:
        pulse.append([label,json.dumps((insights or {}).get(key,[]),ensure_ascii=False)])
    header=PatternFill("solid",fgColor="252A45"); white=Font(bold=True,color="FFFFFF"); side=Side(style="thin",color="E4E7EF")
    for sheet in wb.worksheets:
        sheet.freeze_panes="A2"; sheet.auto_filter.ref=sheet.dimensions
        for cell in sheet[1]: cell.fill=header; cell.font=white
        for row in sheet.iter_rows(min_row=2):
            for cell in row: cell.alignment=Alignment(vertical="top",wrap_text=True); cell.border=Border(bottom=side)
        for col in sheet.columns:
            letter=col[0].column_letter; width=max((len(str(c.value or "")) for c in col[:250]),default=12)
            sheet.column_dimensions[letter].width=min(max(width+2,14),52)
    ws.column_dimensions["E"].width=60; word_ws.column_dimensions["B"].width=32
    pulse.column_dimensions["A"].width=40; pulse.column_dimensions["B"].width=90
    for sheet in (ws,word_ws):
        for row in sheet.iter_rows(min_row=2):
            for cell in row:
                if cell.column in (2,3,4,5): cell.number_format="0.000"
    wb.save(target)

def make_docx(segments,target,language):
    doc=Document(); section=doc.sections[0]
    section.top_margin=Inches(0.65); section.bottom_margin=Inches(0.65); section.left_margin=Inches(0.7); section.right_margin=Inches(0.7)
    title=doc.add_heading("Video Transcript",0); title.alignment=WD_ALIGN_PARAGRAPH.CENTER
    meta=doc.add_paragraph(f"Detected language: {language} | Caption segments: {len(segments)}")
    meta.alignment=WD_ALIGN_PARAGRAPH.CENTER
    table=doc.add_table(rows=1,cols=4); table.alignment=WD_TABLE_ALIGNMENT.CENTER; table.style="Light Shading Accent 1"
    for cell,label in zip(table.rows[0].cells,["No.","Start","End","Caption Text"]): cell.text=label
    for r in rows_for(segments):
        cells=table.add_row().cells
        for cell,value in zip(cells,[r["index"],srt_time(r["start"]),srt_time(r["end"]),r["text"]]):
            cell.text=str(value); cell.vertical_alignment=WD_CELL_VERTICAL_ALIGNMENT.TOP
    doc.add_paragraph("Generated by AI Auto Subtitle Creator Studio")
    doc.save(target)

def make_all_exports(job_dir: Path,segments: list[dict[str,Any]],insights: dict[str,Any]|None=None,language: str="unknown"):
    rows=rows_for(segments); text="\n".join(r["text"] for r in rows).strip()
    write_text(job_dir/"transcript.txt",text+("\n" if text else ""),True)
    make_timecoded_txt(segments,job_dir/"transcript-timecoded.txt")
    make_sbv(segments,job_dir/"captions.sbv"); make_ssa(segments,job_dir/"captions.ssa")
    make_csv_tsv(segments,job_dir/"captions.csv",","); make_csv_tsv(segments,job_dir/"captions.tsv","\t")
    make_xlsx(segments,job_dir/"captions.xlsx",insights,language)
    make_docx(segments,job_dir/"transcript.docx",language)
    make_markdown(segments,job_dir/"transcript.md",language); make_html(segments,job_dir/"transcript.html",language)
    bundle_files = [
        "captions.srt", "captions.vtt", "captions.ass", "captions.ssa", "captions.sbv",
        "transcript.txt", "transcript-timecoded.txt", "captions.csv", "captions.tsv",
        "captions.xlsx", "transcript.docx", "transcript.md", "transcript.html",
        "transcript.json", "creator_report.json",
    ]
    with zipfile.ZipFile(job_dir/"all-exports.zip", "w", compression=zipfile.ZIP_DEFLATED) as archive:
        for name in bundle_files:
            file_path = job_dir/name
            if file_path.is_file(): archive.write(file_path, arcname=name)
