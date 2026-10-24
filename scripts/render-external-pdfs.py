from pathlib import Path
from hashlib import sha256
import argparse
import json
import re, sys
sys.stdout.reconfigure(encoding='utf-8')

from reportlab.lib import colors
from reportlab.lib.enums import TA_LEFT, TA_CENTER
from reportlab.lib.pagesizes import A4
from reportlab.lib.styles import ParagraphStyle, getSampleStyleSheet
from reportlab.lib.units import mm
from reportlab.pdfbase import pdfmetrics
from reportlab.pdfbase.ttfonts import TTFont
from reportlab.platypus import (BaseDocTemplate, Frame, PageTemplate, Paragraph,
                                Spacer, Table, TableStyle, KeepTogether, PageBreak)
from pypdf import PdfReader

root=Path(__file__).resolve().parent.parent
font=Path(r'C:\Windows\Fonts\msyh.ttc')
if not font.is_file(): raise SystemExit('Microsoft YaHei TTC not found')
pdfmetrics.registerFont(TTFont('TongYu',str(font),subfontIndex=0))
navy=colors.HexColor('#173642');teal=colors.HexColor('#137C78');muted=colors.HexColor('#53636B')
styles=getSampleStyleSheet()
styles.add(ParagraphStyle('TitleCN',parent=styles['Title'],fontName='TongYu',fontSize=21,leading=28,textColor=navy,alignment=TA_LEFT,spaceAfter=7*mm,keepWithNext=True))
styles.add(ParagraphStyle('SubCN',fontName='TongYu',fontSize=9,leading=14,textColor=muted,spaceAfter=4*mm))
styles.add(ParagraphStyle('HeadCN',fontName='TongYu',fontSize=13,leading=19,textColor=teal,spaceBefore=5*mm,spaceAfter=2*mm,keepWithNext=True))
styles.add(ParagraphStyle('AccountHeadCN',fontName='TongYu',fontSize=11.2,leading=16,textColor=teal,spaceBefore=1*mm,spaceAfter=2*mm,keepWithNext=True))
styles.add(ParagraphStyle('BodyCN',fontName='TongYu',fontSize=10.2,leading=16,textColor=colors.HexColor('#263238'),spaceAfter=2.0*mm,wordWrap='CJK'))
styles.add(ParagraphStyle('BulletCN',parent=styles['BodyCN'],leftIndent=5*mm,firstLineIndent=-3.5*mm,spaceAfter=1.5*mm))
styles.add(ParagraphStyle('SmallCN',fontName='TongYu',fontSize=8.3,leading=12,textColor=muted,wordWrap='CJK'))
styles.add(ParagraphStyle('CellCN',fontName='TongYu',fontSize=8.8,leading=13,textColor=colors.HexColor('#263238'),wordWrap='CJK'))
styles.add(ParagraphStyle('CellHeadCN',fontName='TongYu',fontSize=8.8,leading=13,textColor=colors.white,wordWrap='CJK'))
styles.add(ParagraphStyle('CodeCN',fontName='TongYu',fontSize=8.7,leading=13,textColor=colors.HexColor('#263238'),spaceAfter=1*mm,wordWrap='CJK',leftIndent=3*mm))

def esc(s):
    return s.replace('&','&amp;').replace('<','&lt;').replace('>','&gt;')

def page(canvas,doc):
    canvas.saveState();w,h=A4
    canvas.setFillColor(navy);canvas.rect(0,h-7*mm,w,7*mm,fill=1,stroke=0)
    canvas.setFont('TongYu',8);canvas.setFillColor(muted)
    canvas.drawString(20*mm,11*mm,'通语客服  |  TongYuDesk')
    canvas.drawRightString(w-20*mm,11*mm,f'{doc.page}')
    canvas.setStrokeColor(colors.HexColor('#D9E1E4'));canvas.setLineWidth(.5)
    canvas.line(20*mm,16*mm,w-20*mm,16*mm);canvas.restoreState()

def paragraph(text,style='BodyCN'):
    return Paragraph(esc(text).replace('\n','<br/>'),styles[style])

def price_table(lines):
    hdr=['套餐','订阅参考价','坐席上限','月消息额度']
    matrix=[[paragraph(x,'CellHeadCN') for x in hdr]]
    for line in lines:
        m=re.match(r'^(体验版|专业版|旗舰版|企业版)：(.+?)[；;]\s*(\d+) 个坐席[；;]\s*每月 ([\d,]+) 条消息。?$',line)
        if not m: return None
        matrix.append([paragraph(m.group(1),'CellCN'),paragraph(m.group(2),'CellCN'),paragraph(m.group(3),'CellCN'),paragraph(m.group(4),'CellCN')])
    t=Table(matrix,colWidths=[32*mm,43*mm,32*mm,38*mm],repeatRows=1,hAlign='LEFT')
    t.setStyle(TableStyle([
        ('BACKGROUND',(0,0),(-1,0),navy),('BACKGROUND',(0,1),(-1,-1),colors.white),
        ('GRID',(0,0),(-1,-1),.45,colors.HexColor('#D9D9D9')),
        ('VALIGN',(0,0),(-1,-1),'MIDDLE'),('LEFTPADDING',(0,0),(-1,-1),7),('RIGHTPADDING',(0,0),(-1,-1),7),
        ('TOPPADDING',(0,0),(-1,-1),7),('BOTTOMPADDING',(0,0),(-1,-1),7),
    ]));return t

def story_from(text,title_override=None,compact_sections=False):
    lines=text.replace('\r\n','\n').split('\n');flow=[]
    original_title=lines.pop(0) if lines else '通语客服'
    title=title_override or original_title
    flow.append(Paragraph(esc(title),styles['TitleCN']))
    section_style='AccountHeadCN' if compact_sections else 'HeadCN'
    pending=[]; code=False; code_lines=[]
    for line in lines:
        s=line.strip()
        if s.startswith('```'):
            if code:
                body='<br/>'.join(esc(x).replace(' ', '&nbsp;') or '&nbsp;' for x in code_lines)
                block=Table([[Paragraph(body,styles['CodeCN'])]],colWidths=[170*mm])
                block.setStyle(TableStyle([('BACKGROUND',(0,0),(-1,-1),colors.HexColor('#F1F5F6')),('LEFTPADDING',(0,0),(-1,-1),8),('RIGHTPADDING',(0,0),(-1,-1),8),('TOPPADDING',(0,0),(-1,-1),8),('BOTTOMPADDING',(0,0),(-1,-1),8)]))
                flow.extend([KeepTogether([block]),Spacer(1,3*mm)])
                code_lines=[]
            code=not code
            continue
        if code:
            code_lines.append(line);continue
        if not s:
            if pending:
                if len(pending)==4 and all(re.match(r'^(体验版|专业版|旗舰版|企业版)：',x) for x in pending):
                    table=price_table(pending)
                    if table: flow.extend([table,Spacer(1,3*mm)]);pending=[];continue
                flow.append(paragraph(' '.join(pending)));pending=[]
            if not flow or not flow[-1].getKeepWithNext():
                flow.append(Spacer(1,1*mm))
            continue
        if s.startswith('资料版本：') or s.startswith('版本：') or s.startswith('复核日期：'):
            flow.append(paragraph(s,'SubCN'));continue
        if re.match(r'^\d+\. (适用范围|接入前|匿名客户|关联已登录|iframe|可靠性与|接入验收)',s) or re.match(r'^附录 [A-G] ',s) or re.match(r'^[一二三四五六七八九十]+、',s):
            if pending:flow.append(paragraph(' '.join(pending)));pending=[]
            flow.append(Paragraph(esc(s),styles[section_style]));continue
        if s == '附录 详细接口契约':
            if pending:flow.append(paragraph(' '.join(pending)));pending=[]
            flow.append(PageBreak());continue
        customer_heading=compact_sections and s in {'登录地址','主管账号','客服账号','密码修改','账号扩展','企业与服务地址','接入安排'}
        is_head=customer_heading or (len(s)<=22 and not re.search(r'[。；;：:]$',s) and (s.endswith(('范围','方案','接待','群聊','开通','身份','验收','功能','入口','配置','处理','说明','保障','额度','步骤','流程','协作','接入','交付','报价','角色','部署','授权','操作','登录')) or s in {'产品概述','主要功能','适用场景','套餐参考','产品定位','会话与客户管理','团队接待','账号交付','操作步骤','客服入口','登录信息','增加账号','当前已具备','商城店铺与店员接入','福利群接入','商品与订单卡片','开放 API 与消息同步','Webhook','错误处理','开发分工与验收','接入配置单'}))
        if is_head:
            if pending:flow.append(paragraph(' '.join(pending)));pending=[]
            if s=='套餐参考':
                flow.append(PageBreak())
            flow.append(Paragraph(esc(s),styles[section_style]));continue
        if s.startswith(('- ','* ')):
            if pending:flow.append(paragraph(' '.join(pending)));pending=[]
            flow.append(paragraph('•  '+s[2:],'BulletCN'));continue
        if re.match(r'^(体验版|专业版|旗舰版|企业版)：',s):
            pending.append(s)
        else:
            if pending: flow.append(paragraph(' '.join(pending)));pending=[]
            item=paragraph(s)
            if s=='商城后端调用：' or s.startswith('POST /api/v1/marketplace/shops/{shopId}/conversations/{id}/cards'):
                item.keepWithNext=True
            flow.append(item)
    if code:raise ValueError('Unclosed code block')
    if pending:flow.append(paragraph(' '.join(pending)))
    return flow

def make_pdf(out,inputs,title,allow_credentials=False):
    parts=[(root/p).read_text(encoding='utf-8-sig').strip() for p in inputs]
    credential_pattern=r'(?im)\brdk_[A-Za-z0-9_-]{20,}|^\s*(?:初始密码|当前密码|密码|API Key|服务端 API Key)[：:=]\s*(?!通过独立受控渠道|通过受控渠道|待确认|单独提供)'
    if not allow_credentials and any(re.search(credential_pattern,part) for part in parts):
        raise ValueError('Account information requires a registered customer PDF')
    flow=[]
    for i,text in enumerate(parts):
        if i:
            flow.append(PageBreak())
            first=text.splitlines()[0]
            flow.extend(story_from(text,title_override=first,compact_sections=allow_credentials))
        else: flow.extend(story_from(text,title_override=title,compact_sections=allow_credentials))
    target=root/out;target.parent.mkdir(parents=True,exist_ok=True)
    sourcehash=sha256('\n'.join(parts).encode('utf-8')).hexdigest()
    doc=BaseDocTemplate(str(target),pagesize=A4,leftMargin=20*mm,rightMargin=20*mm,topMargin=20*mm,bottomMargin=21*mm,title=title,author='通语客服')
    doc.subject='TongYu document source sha256 '+sourcehash
    frame=Frame(20*mm,20*mm,A4[0]-40*mm,A4[1]-43*mm,id='main',leftPadding=0,rightPadding=0,topPadding=0,bottomPadding=0)
    doc.addPageTemplates(PageTemplate(id='plain',frames=frame,onPage=page));doc.build(flow)
    reader=PdfReader(str(target));extracted='\n'.join(p.extract_text() or '' for p in reader.pages)
    normalized=re.sub(r'\s+','',extracted)
    if len(normalized)<sum(len(re.sub(r'\s+','',x)) for x in parts)*0.57:raise ValueError('PDF extraction lost source content: '+str(target))
    if not allow_credentials and re.search(credential_pattern,extracted):
        raise ValueError('credential-like content found in PDF: '+str(target))
    print(f'{target.relative_to(root)} pages={len(reader.pages)} chars={len(extracted)} sha256={sha256(target.read_bytes()).hexdigest()}')

def safe_public_file(public_dir, name, suffix):
    if not isinstance(name,str) or Path(name).name != name or '/' in name or '\\' in name or Path(name).suffix.lower()!=suffix:
        raise ValueError('Customer PDF configuration requires a plain filename')
    target=public_dir/name
    if target.is_symlink() or target.resolve().parent!=public_dir.resolve():
        raise ValueError('Customer PDF file escapes the public directory')
    return target.relative_to(root)

def main():
    parser=argparse.ArgumentParser(description='从正式 TXT 生成通用 PDF，可选同时生成已登记客户的 PDF。')
    parser.add_argument('--platform',help='已登记的客户唯一 slug，例如 caizhan')
    args=parser.parse_args()
    jobs=[('对外资料/01_通用资料/产品与报价/通语客服产品介绍及年度报价.pdf',
           ['对外资料/01_通用资料/产品与报价/通语客服产品介绍及年度报价.txt'],'通语客服',False),
          ('对外资料/01_通用资料/技术接入/通语客服系统对接文档.pdf',
           ['对外资料/01_通用资料/技术接入/通语客服系统对接文档.txt'],'通语客服技术接入指南',False)]
    if args.platform:
        if not re.fullmatch(r'[a-z0-9][a-z0-9-]{1,62}',args.platform):
            raise ValueError('Invalid customer slug')
        customer=root/'对外资料'/'02_平台专属'/args.platform
        profile_path=root/'docs'/'交付管理'/'客户'/args.platform/'客户档案.json'
        profile=json.loads(profile_path.read_text(encoding='utf-8-sig'))
        if profile.get('customerId')!=args.platform:
            raise ValueError('Customer profile does not match its directory')
        public_dir=customer
        if customer.is_symlink() or customer.parent.is_symlink() or customer.resolve().parent!=customer.parent.resolve():
            raise ValueError('Customer public directory must not be a link')
        declared=profile.get('deliverableFiles',[])
        credential_files=profile.get('credentialFiles',[])
        if any(name not in declared for name in credential_files):
            raise ValueError('Customer credential files must be in the delivery allowlist')
        for doc in profile.get('pdfDocuments',[]):
            if not doc.get('sources') or not doc.get('title'):
                raise ValueError('Customer PDF needs a title and TXT sources')
            names=[doc['output'],*doc['sources']]
            if any(name not in declared for name in names):
                raise ValueError('Customer PDF output and sources must be in the delivery allowlist')
            output=safe_public_file(public_dir,doc['output'],'.pdf')
            sources=[safe_public_file(public_dir,name,'.txt') for name in doc['sources']]
            allows_credentials=doc['output'] in credential_files
            if any(name in credential_files for name in doc['sources']) and not allows_credentials:
                raise ValueError('A PDF containing account information must be registered as a customer credential file')
            jobs.append((output,sources,doc['title'],allows_credentials))
    for output,sources,title,allows_credentials in jobs:
        make_pdf(output,sources,title,allow_credentials=allows_credentials)

if __name__=='__main__':
    main()
