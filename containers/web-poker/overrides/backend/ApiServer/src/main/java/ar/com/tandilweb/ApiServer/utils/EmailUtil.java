package ar.com.tandilweb.ApiServer.utils;

import java.util.Date;
import java.util.Properties;

import javax.mail.Message;
import javax.mail.MessagingException;
import javax.mail.Session;
import javax.mail.internet.AddressException;
import javax.mail.internet.InternetAddress;
import javax.mail.internet.MimeMessage;

import org.springframework.beans.factory.annotation.Value;
import org.springframework.stereotype.Component;

import com.sun.mail.smtp.SMTPTransport;

@Component
public class EmailUtil {
	
	@Value("${mail.smtpserver}")
	private String smtpserver;
	
	@Value("${mail.smtpport:587}")
	private int smtpport;
	
	@Value("${mail.username:}")
	private String username;
	
	@Value("${mail.from:${mail.email}}")
	private String from;
	
	@Value("${mail.password}")
	private String password;
	
	@Value("${mail.transport:smtp}")
	private String transport;
	
	@Value("${mail.starttls:true}")
	private boolean starttls;
	
	
	public void sendMail(String to, String subject , String message) {
		 Properties props = new Properties();
	        props.put("mail.transport.protocol", transport);
	        props.put("mail.smtp.host", smtpserver);
	        props.put("mail.smtp.port", String.valueOf(smtpport));
	        props.put("mail.smtp.auth", "true");
	        props.put("mail.smtp.starttls.enable", Boolean.toString(starttls));
	        props.put("mail.smtp.ssl.trust", smtpserver);
	        Session session = Session.getInstance(props, null);
	        Message msg = new MimeMessage(session);
	        try {
				String authUser = (username == null || username.trim().isEmpty()) ? from : username;
				msg.setFrom(new InternetAddress(from));
				msg.setRecipients(Message.RecipientType.TO,
		        InternetAddress.parse(to, false));
		        msg.setSubject(subject);
		        msg.setText(message);
		        msg.setSentDate(new Date());
		        SMTPTransport t =
		            (SMTPTransport)session.getTransport(transport);
		        t.connect(smtpserver, smtpport, authUser, password);
		        t.sendMessage(msg, msg.getAllRecipients());
		        System.out.println("Response: " + t.getLastServerResponse());
		        t.close();
			} catch (AddressException e) {
				e.printStackTrace();
			} catch (MessagingException e) {
				e.printStackTrace();
			};
	}

}
