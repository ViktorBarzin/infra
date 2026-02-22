variable "index_html" {

  default = <<EOT
<h1>How to activate windows</h1>
Open the following link and find a key for you version of windows: </br>
<b><a href="https://goo.gl/BcrPjW" target="_blank">https://goo.gl/BcrPjW</a></b>
</br>
</br>
Open cmd as <b>Administrator</b> and run the following: </br>
</br>
<b>slmgr.vbs /ipk key_for_your_windows</b>
</br>
<b>slmgr.vbs /skms kms.viktorbarzin.me </b>
<br>
<b>
    slmgr /ato
</b>
<br>
<p>
<h3> If you have an evaluation windows, you need to change it to retail one. This is how:</h3>
<br>
From an elevated command prompt, determine the current edition name with the command <br>
<strong>DISM /online /Get-CurrentEdition</strong>.
<br>Make note of the edition ID, an abbreviated form of the edition name. Then run
<br>
<strong>DISM /online /Set-Edition:<edition ID> /ProductKey:XXXXX-XXXXX-XXXXX-XXXXX-XXXXX /AcceptEula</strong>
<br> providing the edition ID and a retail product key. The server will restart
</p>
<hr>


<h1>How to activate Microsoft Office</h1>
<br>
<b>
    CD \Program Files\Microsoft Office\Office16 </b> OR <b>CD \Program Files (x86)\Microsoft Office\Office16
</b>
<br>
<b>
    cscript ospp.vbs /sethst:kms.viktorbarzin.me
</b>
<br>
<b>
    cscript ospp.vbs /inpkey:xxxxx-xxxxx-xxxxx-xxxxx-xxxxx
</b>
<br>
where 'xxxx' is a key for your office. Some examples for office 2016 - <a
    href="https://www.techdee.com/microsoft-office-2016-product-key/">https://www.techdee.com/microsoft-office-2016-product-key/</a>
<br>
<b>
    cscript ospp.vbs /act
</b>

<br>
<br>
If you messed up activation settings reset them using
<br>
slmgr /upk

<br>
slmgr /cpky
<br>
and
<br>
slmgr /rearm

<h3>Buy me a beer :P</h3>
EOT
}
