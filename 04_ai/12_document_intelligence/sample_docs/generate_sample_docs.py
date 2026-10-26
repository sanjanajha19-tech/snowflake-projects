"""
Generate fictional sample documents for ACCEL asset 12 (Document Intelligence).

Creates in this folder:
  invoices/INV-2026-0141_Northwind_Components.pdf
  invoices/INV-2026-0388_Bluepeak_Logistics.pdf
  invoices/INV-2026-0912_Saffron_Office_Supplies.pdf   (total deliberately wrong -> exception demo)
  contracts/MSA_Contoso_Analytics_Acme_Manufacturing.pdf
  contracts/SupplyAgreement_Riverbend_Polymers_Acme_Manufacturing.pdf

All company names, GSTINs and people are fictional.
Requires: pip install reportlab
Run:      python3 generate_sample_docs.py
"""

import os

from reportlab.lib import colors
from reportlab.lib.pagesizes import A4
from reportlab.lib.styles import ParagraphStyle, getSampleStyleSheet
from reportlab.lib.units import mm
from reportlab.platypus import Paragraph, SimpleDocTemplate, Spacer, Table, TableStyle

HERE = os.path.dirname(os.path.abspath(__file__))
STYLES = getSampleStyleSheet()
BODY = ParagraphStyle("body", parent=STYLES["Normal"], fontSize=10, leading=14)
SMALL = ParagraphStyle("small", parent=STYLES["Normal"], fontSize=8, leading=10, textColor=colors.grey)
H1 = STYLES["Title"]
H2 = STYLES["Heading2"]

BUYER = {
    "name": "Acme Manufacturing Pvt Ltd",
    "address": "Plot 22, MIDC Industrial Area, Pune, Maharashtra 411019, India",
    "gstin": "27AAACA1234F1Z5",
}

INVOICES = [
    {
        "file": "INV-2026-0141_Northwind_Components.pdf",
        "number": "INV-2026-0141",
        "date": "2026-07-14",
        "due": "2026-08-13",
        "po": "PO-104552",
        "vendor": "Northwind Components Pvt Ltd",
        "vendor_address": "14 Electronics City Phase 1, Bengaluru, Karnataka 560100, India",
        "vendor_gstin": "29AABCN4521K1Z8",
        "tax_label": "IGST 18%",
        "tax_rate": 0.18,
        "lines": [
            ("Precision bearing 6204-2RS", 400, 85.00),
            ("Hydraulic seal kit HS-40", 120, 410.00),
            ("Stainless fastener pack M8 (100 pcs)", 60, 655.50),
        ],
        "total_override": None,
    },
    {
        "file": "INV-2026-0388_Bluepeak_Logistics.pdf",
        "number": "INV-2026-0388",
        "date": "2026-08-02",
        "due": "2026-09-01",
        "po": "PO-104871",
        "vendor": "Bluepeak Logistics LLP",
        "vendor_address": "Warehouse 7, Bhiwandi Logistics Park, Thane, Maharashtra 421302, India",
        "vendor_gstin": "27AAKFB7788Q1Z3",
        "tax_label": "CGST 9% + SGST 9%",
        "tax_rate": 0.18,
        "lines": [
            ("Full truck load Pune - Chennai (32 ft)", 3, 48500.00),
            ("Warehousing charges July 2026 (pallet-days)", 950, 22.00),
            ("Loading / unloading labour", 6, 1800.00),
            ("Fuel surcharge", 1, 7350.00),
        ],
        "total_override": None,
    },
    {
        "file": "INV-2026-0912_Saffron_Office_Supplies.pdf",
        "number": "INV-2026-0912",
        "date": "2026-09-05",
        "due": "2026-10-05",
        "po": "PO-105230",
        "vendor": "Saffron Office Supplies",
        "vendor_address": "221 MG Road, Indore, Madhya Pradesh 452001, India",
        "vendor_gstin": "23ABCPS9876M1ZK",
        "tax_label": "IGST 18%",
        "tax_rate": 0.18,
        "lines": [
            ("A4 copier paper 75 gsm (box of 5 reams)", 80, 1150.00),
            ("Toner cartridge LJ-26A", 12, 4200.00),
            ("Ergonomic office chair EC-200", 10, 8900.00),
        ],
        # Deliberately inconsistent total (correct total is 273,052.00) to demo the exceptions view
        "total_override": 283052.00,
    },
]

CONTRACTS = [
    {
        "file": "MSA_Contoso_Analytics_Acme_Manufacturing.pdf",
        "title": "MASTER SERVICES AGREEMENT",
        "number": "MSA-2026-017",
        "party_a": "Contoso Analytics Pvt Ltd, a company incorporated in India with its registered office at 5th Floor, Cyber Towers, Hyderabad 500081 (\"Service Provider\")",
        "party_b": "Acme Manufacturing Pvt Ltd, a company incorporated in India with its registered office at Plot 22, MIDC Industrial Area, Pune 411019 (\"Client\")",
        "effective": "1 April 2026",
        "clauses": [
            ("1. Services", "The Service Provider shall provide data engineering, analytics and managed platform services as described in each Statement of Work (SOW) executed under this Agreement."),
            ("2. Term", "This Agreement commences on the Effective Date of 1 April 2026 and continues for an initial term of thirty-six (36) months. It renews automatically for successive twelve (12) month periods unless either party gives written notice of non-renewal at least ninety (90) days before the end of the then-current term."),
            ("3. Fees and Payment", "Fees are set out in each SOW. Invoices are payable within thirty (30) days of receipt. Late payments bear interest at 1% per month."),
            ("4. Confidentiality", "Each party shall protect the other party's Confidential Information with at least the same degree of care it uses for its own, and in no event less than reasonable care, for five (5) years after termination."),
            ("5. Limitation of Liability", "Except for breach of confidentiality, fraud or wilful misconduct, each party's total aggregate liability under this Agreement shall not exceed the total fees paid or payable by the Client in the twelve (12) months preceding the claim, subject to a maximum of INR 2,50,00,000 (Rupees Two Crore Fifty Lakh). Neither party is liable for indirect or consequential losses."),
            ("6. Termination", "Either party may terminate this Agreement for convenience on ninety (90) days' written notice. Either party may terminate immediately on written notice if the other party commits a material breach that is not remedied within thirty (30) days of notice, or becomes insolvent."),
            ("7. Governing Law", "This Agreement is governed by the laws of India. Courts at Pune have exclusive jurisdiction."),
        ],
        "signatories": [("For Contoso Analytics Pvt Ltd", "Priya Raman, Director"),
                        ("For Acme Manufacturing Pvt Ltd", "Arjun Mehta, Chief Financial Officer")],
    },
    {
        "file": "SupplyAgreement_Riverbend_Polymers_Acme_Manufacturing.pdf",
        "title": "SUPPLY AGREEMENT",
        "number": "SA-2026-044",
        "party_a": "Riverbend Polymers Ltd, a company incorporated in India with its registered office at Survey No. 88, Vapi GIDC, Gujarat 396195 (\"Supplier\")",
        "party_b": "Acme Manufacturing Pvt Ltd, a company incorporated in India with its registered office at Plot 22, MIDC Industrial Area, Pune 411019 (\"Buyer\")",
        "effective": "15 June 2026",
        "clauses": [
            ("1. Supply of Products", "The Supplier shall manufacture and supply polypropylene granules and engineered polymer compounds to the Buyer against purchase orders issued under this Agreement."),
            ("2. Term", "This Agreement is effective from 15 June 2026 and remains in force for twenty-four (24) months, unless terminated earlier in accordance with clause 7."),
            ("3. Delivery", "The Supplier shall deliver on-time-in-full (OTIF) to the Buyer's Pune plant. OTIF performance below 95% in any calendar quarter entitles the Buyer to a service credit of 2% of that quarter's invoiced value."),
            ("4. Price", "Prices are fixed for the first twelve (12) months and thereafter indexed quarterly to the published polypropylene benchmark price."),
            ("5. Quality and Warranty", "Products shall conform to the agreed specifications. The Supplier warrants the Products for twelve (12) months from delivery."),
            ("6. Liability", "The Supplier's aggregate liability arising out of or in connection with this Agreement is capped at INR 75,00,000 (Rupees Seventy-Five Lakh), except for liability arising from product recalls caused by defective Products, which is uncapped."),
            ("7. Termination", "The Buyer may terminate this Agreement on sixty (60) days' written notice. Either party may terminate with immediate effect if the other party commits a material breach and fails to cure it within fifteen (15) days of written notice."),
            ("8. Governing Law", "This Agreement is governed by the laws of India, with arbitration seated in Mumbai under the Arbitration and Conciliation Act, 1996."),
        ],
        "signatories": [("For Riverbend Polymers Ltd", "Karan Shah, Managing Director"),
                        ("For Acme Manufacturing Pvt Ltd", "Arjun Mehta, Chief Financial Officer")],
    },
]


def money(value):
    return f"{value:,.2f}"


def build_invoice(inv, out_dir):
    path = os.path.join(out_dir, inv["file"])
    doc = SimpleDocTemplate(path, pagesize=A4, leftMargin=18 * mm, rightMargin=18 * mm,
                            topMargin=15 * mm, bottomMargin=15 * mm,
                            title=f"Tax Invoice {inv['number']}", author=inv["vendor"])
    story = [Paragraph("TAX INVOICE", H1)]

    header = [
        [Paragraph(f"<b>{inv['vendor']}</b><br/>{inv['vendor_address']}<br/>GSTIN: {inv['vendor_gstin']}", BODY),
         Paragraph(f"<b>Invoice No:</b> {inv['number']}<br/><b>Invoice Date:</b> {inv['date']}<br/>"
                   f"<b>Due Date:</b> {inv['due']}<br/><b>PO Number:</b> {inv['po']}<br/><b>Currency:</b> INR", BODY)],
    ]
    t = Table(header, colWidths=[100 * mm, 74 * mm])
    t.setStyle(TableStyle([("VALIGN", (0, 0), (-1, -1), "TOP")]))
    story += [t, Spacer(1, 6 * mm)]
    story.append(Paragraph(f"<b>Bill To:</b> {BUYER['name']}<br/>{BUYER['address']}<br/>GSTIN: {BUYER['gstin']}", BODY))
    story.append(Spacer(1, 6 * mm))

    rows = [["#", "Description", "Qty", "Unit Price (INR)", "Line Total (INR)"]]
    subtotal = 0.0
    for i, (desc, qty, price) in enumerate(inv["lines"], start=1):
        line_total = round(qty * price, 2)
        subtotal += line_total
        rows.append([str(i), Paragraph(desc, BODY), str(qty), money(price), money(line_total)])
    subtotal = round(subtotal, 2)
    tax = round(subtotal * inv["tax_rate"], 2)
    total = inv["total_override"] if inv["total_override"] is not None else round(subtotal + tax, 2)
    rows.append(["", "", "", "Subtotal", money(subtotal)])
    rows.append(["", "", "", inv["tax_label"], money(tax)])
    rows.append(["", "", "", "Total Amount Due", money(total)])

    table = Table(rows, colWidths=[10 * mm, 80 * mm, 18 * mm, 32 * mm, 34 * mm])
    n = len(rows)
    table.setStyle(TableStyle([
        ("BACKGROUND", (0, 0), (-1, 0), colors.HexColor("#1f3b5c")),
        ("TEXTCOLOR", (0, 0), (-1, 0), colors.white),
        ("FONTNAME", (0, 0), (-1, 0), "Helvetica-Bold"),
        ("GRID", (0, 0), (-1, n - 4), 0.4, colors.grey),
        ("ALIGN", (2, 1), (-1, -1), "RIGHT"),
        ("FONTNAME", (3, n - 1), (-1, n - 1), "Helvetica-Bold"),
        ("LINEABOVE", (3, n - 3), (-1, n - 3), 0.6, colors.black),
        ("LINEABOVE", (3, n - 1), (-1, n - 1), 0.8, colors.black),
        ("VALIGN", (0, 0), (-1, -1), "MIDDLE"),
    ]))
    story += [table, Spacer(1, 8 * mm)]
    story.append(Paragraph("Payment terms: 30 days from invoice date. Bank: Fictional Bank of India, "
                           "A/C 001122334455, IFSC FBIN0000123.", BODY))
    story.append(Spacer(1, 4 * mm))
    story.append(Paragraph("This is a fictional sample document generated for a Snowflake demo.", SMALL))
    doc.build(story)
    return path


def build_contract(c, out_dir):
    path = os.path.join(out_dir, c["file"])
    doc = SimpleDocTemplate(path, pagesize=A4, leftMargin=20 * mm, rightMargin=20 * mm,
                            topMargin=18 * mm, bottomMargin=18 * mm,
                            title=c["title"], author="Acme Manufacturing Legal")
    story = [Paragraph(c["title"], H1),
             Paragraph(f"Agreement No. {c['number']}", BODY), Spacer(1, 4 * mm),
             Paragraph(f"This {c['title'].title()} (the \"Agreement\") is made and entered into with effect from "
                       f"<b>{c['effective']}</b> (the \"Effective Date\") by and between:", BODY),
             Spacer(1, 3 * mm),
             Paragraph(f"(1) {c['party_a']}; and", BODY),
             Paragraph(f"(2) {c['party_b']}.", BODY),
             Spacer(1, 5 * mm)]
    for heading, text in c["clauses"]:
        story.append(Paragraph(heading, H2))
        story.append(Paragraph(text, BODY))
    story.append(Spacer(1, 10 * mm))
    sig_rows = [[Paragraph(f"<b>{who}</b><br/><br/>______________________<br/>{name}<br/>Date: {c['effective']}", BODY)
                 for who, name in c["signatories"]]]
    story.append(Table(sig_rows, colWidths=[85 * mm, 85 * mm]))
    story.append(Spacer(1, 6 * mm))
    story.append(Paragraph("This is a fictional sample document generated for a Snowflake demo.", SMALL))
    doc.build(story)
    return path


def main():
    inv_dir = os.path.join(HERE, "invoices")
    con_dir = os.path.join(HERE, "contracts")
    os.makedirs(inv_dir, exist_ok=True)
    os.makedirs(con_dir, exist_ok=True)
    for inv in INVOICES:
        print("created", build_invoice(inv, inv_dir))
    for c in CONTRACTS:
        print("created", build_contract(c, con_dir))


if __name__ == "__main__":
    main()
